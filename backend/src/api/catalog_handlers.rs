use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    ItemKind, LastPriceQuery, LookupStatus, NutritionDto, PriceHistoryQuery, PricePointDto, PriceSource,
    ProductInfoDto, ProductLookupDto, ProductLookupQuery, RecognizeLabelRequest,
};
use sqlx::types::Json as DbJson;
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::ai_handlers::{charge_scan, read_error, record_usage, refund_scan, resolve_ai};
use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::item_handlers::require_item;
use crate::api::recognize_handlers::check_image;
use crate::catalog::off::{
    bounded, clean, suggest_name, OffOutcome, OffProduct, MAX_BRAND_CHARS, MAX_GRAMS, MAX_KCAL, MAX_NAME_CHARS,
    MAX_QUANTITY_CHARS,
};
use crate::catalog::quantity::with_quantity;
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_barcode;
use crate::receipt_ai::{RawLabel, ReadError};
use crate::security::rate_limit::PRODUCT_LOOKUP_PER_USER;
use crate::state::AppState;

pub const MAX_LABEL_IMAGE_BYTES: usize = 2 * 1024 * 1024;
const FOUND_TTL_DAYS: i64 = 30;
const MISSING_TTL_HOURS: i64 = 24;
const MAX_LANG_LEN: usize = 3;
const DEFAULT_HISTORY_LIMIT: i64 = 30;
const MAX_HISTORY_LIMIT: i64 = 200;

struct CachedProduct
{
    product: Option<DbJson<OffProduct>>,
    fetched_ts: DateTime<Utc>,
}

struct PriceRow
{
    ts: DateTime<Utc>,
    unit_price: Decimal,
    qty: Decimal,
    curr_id: Uuid,
    curr_code: String,
    place_id: Option<Uuid>,
    store_name: Option<String>,
    branch: Option<String>,
    source: String,
    is_shared: bool,
}

impl From<PriceRow> for PricePointDto
{
    fn from(a_row: PriceRow) -> Self
    {
        Self {
            ts: a_row.ts,
            unit_price: a_row.unit_price,
            qty: a_row.qty,
            curr_id: a_row.curr_id,
            curr_code: a_row.curr_code,
            place_id: a_row.place_id,
            store_name: a_row.store_name,
            branch: a_row.branch,
            source: if a_row.source == "manual"
            {
                PriceSource::Manual
            }
            else
            {
                PriceSource::Receipt
            },
            is_shared: a_row.is_shared,
        }
    }
}

pub async fn lookup_product(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_barcode): ApiPath<String>,
    ApiQuery(a_query): ApiQuery<ProductLookupQuery>,
) -> Result<Json<ProductLookupDto>, ApiError>
{
    let barcode = clean_barcode(Some(&a_barcode))?.ok_or(ApiError::Validation("barcode"))?;
    let lang = a_query
        .lang
        .filter(|lang| (2..=MAX_LANG_LEN).contains(&lang.len()) && lang.chars().all(|chr| chr.is_ascii_alphabetic()));

    let cached = sqlx::query_as!(
        CachedProduct,
        r#"SELECT product AS "product: DbJson<OffProduct>", fetched_ts FROM off_products WHERE barcode = $1"#,
        barcode
    )
    .fetch_optional(&a_state.db)
    .await?;

    if let Some(entry) = cached.as_ref().filter(|entry| is_fresh(entry))
    {
        return Ok(Json(cached_reply(entry, &barcode, lang.as_deref())));
    }

    a_state
        .limiter
        .hit(&format!("product-lookup:{}", a_user.user_id), &PRODUCT_LOOKUP_PER_USER)?;

    let reply = match a_state.off.fetch(&barcode).await
    {
        OffOutcome::Found(product) =>
        {
            store_product(&a_state, &barcode, Some(&product)).await?;
            found(product.to_info(&barcode, lang.as_deref()))
        }
        OffOutcome::NotFound =>
        {
            store_product(&a_state, &barcode, None).await?;
            missing(LookupStatus::NotFound)
        }
        OffOutcome::Unavailable => match cached.as_ref()
        {
            Some(entry) => cached_reply(entry, &barcode, lang.as_deref()),
            None => missing(LookupStatus::Unavailable),
        },
    };

    Ok(Json(reply))
}

pub async fn recognize_label(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<RecognizeLabelRequest>,
) -> Result<Json<ProductInfoDto>, ApiError>
{
    let image = check_image(&a_req.media_type, &a_req.image, MAX_LABEL_IMAGE_BYTES)?;

    let mut conn = a_state.db.acquire().await?;
    let resolved = resolve_ai(&a_state, &mut conn, a_user.user_id)
        .await?
        .ok_or(ApiError::Conflict("RECOGNITION_DISABLED"))?;
    drop(conn);
    charge_scan(&a_state, a_user.user_id, &resolved).await?;

    let outcome = match a_state.receipt_ai.read_label(&resolved.target, &image).await
    {
        Ok(outcome) => outcome,
        Err(err) =>
        {
            if matches!(err, ReadError::KeyRejected | ReadError::ModelRejected)
            {
                refund_scan(&a_state, a_user.user_id, resolved.is_own_key).await?;
            }
            return Err(match read_error(err, resolved.is_own_key)
            {
                ApiError::Conflict("RECEIPT_UNREADABLE") => ApiError::Conflict("LABEL_UNREADABLE"),
                other => other,
            });
        }
    };
    record_usage(&a_state, a_user.user_id, resolved.is_own_key, outcome.usage).await?;

    if !outcome.label.is_label
    {
        return Err(ApiError::Conflict("NOT_A_LABEL"));
    }

    Ok(Json(label_info(outcome.label)))
}

pub async fn price_history(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<PriceHistoryQuery>,
) -> Result<Json<Vec<PricePointDto>>, ApiError>
{
    let limit = a_query
        .limit
        .unwrap_or(DEFAULT_HISTORY_LIMIT)
        .clamp(1, MAX_HISTORY_LIMIT);
    let mut conn = a_state.db.acquire().await?;
    require_item(&mut conn, a_id).await?;

    load_price_points(&mut conn, a_id, a_user.user_id, None, None, limit)
        .await
        .map(Json)
}

pub async fn last_price(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<LastPriceQuery>,
) -> Result<Json<Option<PricePointDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    require_item(&mut conn, a_id).await?;

    let latest = load_price_points(&mut conn, a_id, a_user.user_id, a_query.place_id, a_query.curr_id, 1)
        .await?
        .into_iter()
        .next();
    Ok(Json(latest))
}

fn is_fresh(a_entry: &CachedProduct) -> bool
{
    let ttl = if a_entry.product.is_some()
    {
        Duration::days(FOUND_TTL_DAYS)
    }
    else
    {
        Duration::hours(MISSING_TTL_HOURS)
    };
    Utc::now() - a_entry.fetched_ts < ttl
}

fn cached_reply(a_entry: &CachedProduct, a_barcode: &str, a_lang: Option<&str>) -> ProductLookupDto
{
    match a_entry.product.as_ref()
    {
        Some(product) => found(product.0.to_info(a_barcode, a_lang)),
        None => missing(LookupStatus::NotFound),
    }
}

fn found(a_product: ProductInfoDto) -> ProductLookupDto
{
    ProductLookupDto {
        status: LookupStatus::Found,
        product: Some(a_product),
    }
}

fn missing(a_status: LookupStatus) -> ProductLookupDto
{
    ProductLookupDto {
        status: a_status,
        product: None,
    }
}

async fn store_product(a_state: &AppState, a_barcode: &str, a_product: Option<&OffProduct>) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        INSERT INTO off_products (barcode, product, fetched_ts)
        VALUES ($1, $2, NOW())
        ON CONFLICT (barcode) DO UPDATE SET product = EXCLUDED.product, fetched_ts = EXCLUDED.fetched_ts
        "#,
        a_barcode,
        a_product.map(DbJson) as Option<DbJson<&OffProduct>>
    )
    .execute(&a_state.db)
    .await?;
    Ok(())
}

fn label_info(a_label: RawLabel) -> ProductInfoDto
{
    let name = clean(a_label.name.as_deref(), MAX_NAME_CHARS);
    let brand = clean(a_label.brand.as_deref(), MAX_BRAND_CHARS);
    let quantity = clean(a_label.quantity.as_deref(), MAX_QUANTITY_CHARS);
    let nutrition = NutritionDto {
        kcal: bounded(a_label.kcal, MAX_KCAL),
        prot: bounded(a_label.protein, MAX_GRAMS),
        fat: bounded(a_label.fat, MAX_GRAMS),
        carb: bounded(a_label.carbohydrates, MAX_GRAMS),
        piece_g: None,
    };
    let kind = match a_label.kind.as_deref()
    {
        Some("food") => Some(ItemKind::Food),
        Some("product") => Some(ItemKind::Product),
        _ => None,
    };

    with_quantity(ProductInfoDto {
        kind,
        suggested_name: suggest_name(name.as_deref(), brand.as_deref(), quantity.as_deref()),
        name,
        brand,
        quantity,
        barcode: clean_barcode(a_label.barcode.as_deref()).ok().flatten(),
        nutrition: (!nutrition.is_empty()).then_some(nutrition),
        net_qty: None,
        net_measure: None,
    })
}

async fn load_price_points(
    a_conn: &mut PgConnection,
    a_item_id: Uuid,
    a_user_id: Uuid,
    a_place_id: Option<Uuid>,
    a_curr_id: Option<Uuid>,
    a_limit: i64,
) -> Result<Vec<PricePointDto>, ApiError>
{
    let rows = sqlx::query_as!(
        PriceRow,
        r#"
        WITH sharers AS (
            SELECT DISTINCT theirs.user_id
            FROM family_mems mine
            JOIN family_mems theirs ON theirs.family_id = mine.family_id
            WHERE mine.user_id = $2 AND theirs.user_id <> $2
        ),
        obs AS (
            SELECT r.owner_id, r.place_id, r.place_addr_id, r.merchant_id, r.merchant_name, r.curr_id,
                   ri.amount / ri.qty AS unit_price, ri.qty, r.receipt_ts AS ts, r.created_ts, 'receipt' AS source
            FROM receipt_items ri
            JOIN receipts r ON r.id = ri.receipt_id
            WHERE ri.item_id = $1
              AND (r.owner_id = $2 OR r.owner_id IN (SELECT user_id FROM sharers))
            UNION ALL
            SELECT ip.owner_id, ip.place_id, ip.place_addr_id, NULL::uuid, ip.merchant_name, ip.curr_id,
                   ip.price / ip.qty, ip.qty, ip.seen_ts, ip.created_ts, 'manual'
            FROM item_prices ip
            WHERE ip.item_id = $1
              AND (ip.owner_id = $2 OR ip.owner_id IN (SELECT user_id FROM sharers))
        )
        SELECT
            o.ts AS "ts!",
            ROUND(o.unit_price, 2) AS "unit_price!",
            o.qty AS "qty!",
            o.curr_id AS "curr_id!",
            c.code AS curr_code,
            o.place_id,
            COALESCE(pl.name, m.name, o.merchant_name) AS store_name,
            CASE WHEN pa.id IS NOT NULL THEN addr_label(ci.name, st.name, pa.house_num, pa.zip) END AS branch,
            o.source AS "source!",
            (o.owner_id <> $2) AS "is_shared!"
        FROM obs o
        JOIN currencies c ON c.id = o.curr_id
        LEFT JOIN places pl ON pl.id = o.place_id
        LEFT JOIN place_addrs pa ON pa.id = o.place_addr_id
        LEFT JOIN streets st ON st.id = pa.street_id
        LEFT JOIN cities ci ON ci.id = pa.city_id
        LEFT JOIN merchants m ON m.id = o.merchant_id
        WHERE $4::uuid IS NULL OR o.curr_id = $4
        ORDER BY COALESCE(o.place_id = $3, FALSE) DESC, o.ts DESC, o.created_ts DESC
        LIMIT $5
        "#,
        a_item_id,
        a_user_id,
        a_place_id,
        a_curr_id,
        a_limit
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(rows.into_iter().map(PricePointDto::from).collect())
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn label_values_are_cleaned_and_bounded()
    {
        let info = label_info(RawLabel {
            is_label: true,
            name: Some("  Йогурт  питний 2,5% ".into()),
            brand: Some("Галичина".into()),
            quantity: Some("500 г".into()),
            barcode: Some("123".into()),
            kind: Some("food".into()),
            kcal: Some(75.456),
            protein: Some(3.1),
            fat: Some(250.0),
            carbohydrates: None,
        });

        assert_eq!(info.name.as_deref(), Some("Йогурт питний 2,5%"));
        assert_eq!(
            info.suggested_name.as_deref(),
            Some("Йогурт питний 2,5% Галичина 500 г")
        );
        assert_eq!(info.kind, Some(ItemKind::Food));
        assert_eq!(info.barcode, None);
        let nutrition = info.nutrition.unwrap();
        assert_eq!(nutrition.kcal, Some(Decimal::new(7546, 2)));
        assert_eq!(nutrition.fat, None);
        assert_eq!(nutrition.carb, None);
    }

    #[test]
    fn missing_products_expire_sooner_than_found_ones()
    {
        let stale_missing = CachedProduct {
            product: None,
            fetched_ts: Utc::now() - Duration::hours(MISSING_TTL_HOURS + 1),
        };
        let recent_found = CachedProduct {
            product: Some(DbJson(OffProduct::default())),
            fetched_ts: Utc::now() - Duration::days(FOUND_TTL_DAYS - 1),
        };

        assert!(!is_fresh(&stale_missing));
        assert!(is_fresh(&recent_found));
    }
}
