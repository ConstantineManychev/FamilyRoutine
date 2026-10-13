use axum::extract::State;
use axum::Json;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    FeaturesDto, ItemKind, ItemUnit, LineMatch, NewPlaceRequest, RecognizeReceiptRequest, RecognizedLineDto,
    RecognizedReceiptDto,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::ai_handlers::{charge_scan, read_error, record_usage, refund_scan, resolve_ai};
use crate::api::extract::{ApiJson, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{check_money, check_qty, clean_barcode, money};
use crate::receipt_ai::{RawDiscount, RawLine, RawReceipt, ReadError, ReceiptImage};
use crate::state::AppState;

const MAX_IMAGE_BYTES: usize = 5 * 1024 * 1024;
const MIN_IMAGE_BYTES: usize = 100;
const MAX_LINES: usize = 300;
const MAX_TEXT_CHARS: usize = 200;
const MAX_PLACE_PART_CHARS: usize = 100;
const MAX_RECEIPT_AGE_DAYS: i64 = 730;
const PLACE_MATCH_SCORE: f64 = 0.6;
const STREET_MATCH_SCORE: f64 = 0.4;
const SIMILAR_ITEM_SCORE: f64 = 0.55;
const EXACT_ITEM_SCORE: f64 = 0.999;
const DEFAULT_PURCHASE_TIME: NaiveTime = match NaiveTime::from_hms_opt(12, 0, 0)
{
    Some(time) => time,
    None => NaiveTime::MIN,
};

struct CleanLine
{
    text: String,
    name: String,
    kind: ItemKind,
    unit: ItemUnit,
    qty: Decimal,
    unit_price: Option<Decimal>,
    amount: Decimal,
    barcode: Option<String>,
}

struct MatchedItem
{
    id: Uuid,
    name: String,
    unit: ItemUnit,
}

struct ScoredItem
{
    id: Uuid,
    name: String,
    unit: ItemUnit,
    score: f64,
}

struct ScoredPlace
{
    id: Uuid,
    name: String,
    score: f64,
    is_editable: bool,
}

struct ScoredBranch
{
    id: Uuid,
    street_score: f64,
    is_same_house: bool,
    is_same_city: bool,
    is_city_only: bool,
}

pub async fn features(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<FeaturesDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let provider = resolve_ai(&a_state, &mut conn, a_user.user_id)
        .await?
        .map(|resolved| resolved.target.provider);

    Ok(Json(FeaturesDto {
        is_receipt_recognition: provider.is_some(),
        recognition_provider: provider,
    }))
}

pub async fn recognize_receipt(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<RecognizeReceiptRequest>,
) -> Result<Json<RecognizedReceiptDto>, ApiError>
{
    let image = check_image(&a_req.media_type, &a_req.image)?;

    let mut conn = a_state.db.acquire().await?;
    let resolved = resolve_ai(&a_state, &mut conn, a_user.user_id)
        .await?
        .ok_or(ApiError::Conflict("RECOGNITION_DISABLED"))?;
    drop(conn);
    charge_scan(&a_state, a_user.user_id, &resolved).await?;

    let outcome = match a_state.receipt_ai.read(&resolved.target, &image).await
    {
        Ok(outcome) => outcome,
        Err(err) =>
        {
            if matches!(err, ReadError::KeyRejected | ReadError::ModelRejected)
            {
                refund_scan(&a_state, a_user.user_id, resolved.is_own_key).await?;
            }
            return Err(read_error(err, resolved.is_own_key));
        }
    };
    record_usage(&a_state, a_user.user_id, resolved.is_own_key, outcome.usage).await?;

    if !outcome.receipt.is_receipt
    {
        return Err(ApiError::Conflict("NOT_A_RECEIPT"));
    }

    let mut conn = a_state.db.acquire().await?;
    build_draft(&mut conn, a_user.user_id, outcome.receipt, a_req.tz_offset_min)
        .await
        .map(Json)
}

pub fn alias_key(a_text: &str) -> Option<String>
{
    let key: String = a_text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
        .chars()
        .take(MAX_TEXT_CHARS)
        .collect();
    (!key.is_empty()).then_some(key)
}

fn check_image(a_media_type: &str, a_data: &str) -> Result<ReceiptImage, ApiError>
{
    let media_type = match a_media_type
    {
        "image/jpeg" => "image/jpeg",
        "image/png" => "image/png",
        "image/webp" => "image/webp",
        _ => return Err(ApiError::Validation("media_type")),
    };

    let bytes = STANDARD
        .decode(a_data.trim())
        .map_err(|_| ApiError::Validation("image"))?;
    let is_signature_valid = match media_type
    {
        "image/jpeg" => bytes.starts_with(&[0xFF, 0xD8, 0xFF]),
        "image/png" => bytes.starts_with(&[0x89, b'P', b'N', b'G']),
        _ => bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP",
    };
    if !(MIN_IMAGE_BYTES..=MAX_IMAGE_BYTES).contains(&bytes.len()) || !is_signature_valid
    {
        return Err(ApiError::Validation("image"));
    }

    Ok(ReceiptImage {
        media_type,
        data_base64: STANDARD.encode(&bytes),
    })
}

async fn build_draft(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_raw: RawReceipt,
    a_tz_offset_min: i32,
) -> Result<RecognizedReceiptDto, ApiError>
{
    let store_name = clean_part(a_raw.store_name.as_deref());
    let country_code = clean_part(a_raw.country_code.as_deref()).map(|code| code.to_uppercase());
    let address = NewPlaceRequest {
        place_id: None,
        family_id: None,
        name: store_name.clone().unwrap_or_default(),
        country_code: country_code.clone(),
        city: clean_part(a_raw.city.as_deref()),
        street: clean_part(a_raw.street.as_deref()),
        house_num: clean_part(a_raw.house_number.as_deref()),
        zip: clean_part(a_raw.postal_code.as_deref()),
    };
    let currency = resolve_currency(a_conn, a_raw.currency.as_deref(), country_code.as_deref()).await?;

    let (folded, leftover_cents) = fold_line_discounts(a_raw.lines);
    let lines: Vec<CleanLine> = folded.into_iter().filter_map(clean_line).take(MAX_LINES).collect();
    let mut recognized = Vec::with_capacity(lines.len());
    for line in lines
    {
        let found = match_item(a_conn, a_user_id, &line).await?;
        let (item_id, item_name, match_kind) = match found
        {
            Some((item, kind)) => (Some(item.id), Some(item.name), kind),
            None => (None, None, LineMatch::New),
        };
        recognized.push(RecognizedLineDto {
            text: line.text,
            name: line.name,
            kind: line.kind,
            unit: line.unit,
            qty: line.qty,
            unit_price: line.unit_price,
            amount: line.amount,
            barcode: line.barcode,
            item_id,
            item_name,
            match_kind,
        });
    }

    let (place, place_addr_id, new_place) = match store_name.as_deref()
    {
        None => (None, None, None),
        Some(name) => match_place(a_conn, a_user_id, name, &address).await?,
    };

    let lines_total: Decimal = recognized.iter().map(|line| line.amount).sum();
    let discount = (receipt_discount(&a_raw.discounts) + Decimal::new(leftover_cents, 2)).min(lines_total);

    Ok(RecognizedReceiptDto {
        receipt_ts: purchase_ts(a_raw.date.as_deref(), a_raw.time.as_deref(), a_tz_offset_min),
        curr_id: currency.as_ref().map(|(id, _)| *id),
        curr_code: currency.map(|(_, code)| code),
        total: a_raw.total.and_then(to_money),
        lines_total: money(lines_total),
        discount: money(discount),
        store_name,
        place_id: place.as_ref().map(|place| place.id),
        place_name: place.map(|place| place.name),
        place_addr_id,
        new_place,
        lines: recognized,
    })
}

fn clean_part(a_value: Option<&str>) -> Option<String>
{
    let value: String = a_value?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|ch| !ch.is_control())
        .take(MAX_PLACE_PART_CHARS)
        .collect();
    (!value.is_empty()).then_some(value)
}

fn clean_text(a_value: &str) -> String
{
    a_value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|ch| !ch.is_control())
        .take(MAX_TEXT_CHARS)
        .collect()
}

fn to_money(a_value: f64) -> Option<Decimal>
{
    let value = Decimal::try_from(a_value).ok()?.round_dp(2);
    check_money(value, "amount")
        .ok()
        .filter(|amount| *amount >= Decimal::ZERO)
        .map(money)
}

fn to_cents(a_value: f64) -> i64
{
    (a_value * 100.0).round() as i64
}

fn fold_line_discounts(a_lines: Vec<RawLine>) -> (Vec<RawLine>, i64)
{
    let mut kept: Vec<RawLine> = Vec::with_capacity(a_lines.len());
    let mut leftover = 0;

    for line in a_lines
    {
        let cents = to_cents(line.amount);
        if cents >= 0
        {
            kept.push(line);
            continue;
        }

        let Some(last) = kept.last()
        else
        {
            leftover -= cents;
            continue;
        };
        let key = last.text.trim().to_lowercase();
        let group: Vec<usize> = kept
            .iter()
            .enumerate()
            .filter(|(_, other)| other.text.trim().to_lowercase() == key && to_cents(other.amount) > 0)
            .map(|(index, _)| index)
            .collect();
        if group.is_empty()
        {
            leftover -= cents;
            continue;
        }

        let mut rest = -cents;
        let share = rest / group.len() as i64;
        let mut remainder = rest - share * group.len() as i64;
        for index in group
        {
            let target = &mut kept[index];
            let wanted = share + i64::from(remainder > 0);
            remainder -= i64::from(remainder > 0);
            let cut = wanted.min(to_cents(target.amount));
            let amount = to_cents(target.amount) - cut;
            target.amount = amount as f64 / 100.0;
            if target.quantity > 0.0
            {
                target.unit_price = Some(target.amount / target.quantity);
            }
            rest -= cut;
        }
        leftover += rest;
    }

    (kept, leftover)
}

fn receipt_discount(a_discounts: &[RawDiscount]) -> Decimal
{
    a_discounts
        .iter()
        .filter_map(|discount| to_money(discount.amount.abs()))
        .sum()
}

fn clean_line(a_raw: RawLine) -> Option<CleanLine>
{
    let text = clean_text(&a_raw.text);
    let name = Some(clean_text(&a_raw.name))
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| text.clone());
    if name.is_empty()
    {
        return None;
    }

    let amount = to_money(a_raw.amount)?;
    let qty = Decimal::try_from(a_raw.quantity)
        .ok()
        .map(|qty| qty.round_dp(3))
        .and_then(|qty| check_qty(qty).ok())
        .unwrap_or(Decimal::ONE);

    Some(CleanLine {
        text: if text.is_empty() { name.clone() } else { text },
        name,
        kind: match a_raw.kind.as_str()
        {
            "service" => ItemKind::Service,
            "food" => ItemKind::Food,
            _ => ItemKind::Product,
        },
        unit: match a_raw.unit.as_str()
        {
            "kilogram" => ItemUnit::Kilogram,
            "liter" => ItemUnit::Liter,
            "meter" => ItemUnit::Meter,
            "square_meter" => ItemUnit::SquareMeter,
            "hour" => ItemUnit::Hour,
            _ => ItemUnit::Piece,
        },
        qty,
        unit_price: a_raw.unit_price.and_then(to_money),
        amount,
        barcode: clean_barcode(a_raw.barcode.as_deref()).ok().flatten(),
    })
}

fn purchase_ts(a_date: Option<&str>, a_time: Option<&str>, a_tz_offset_min: i32) -> Option<DateTime<Utc>>
{
    let date = NaiveDate::parse_from_str(a_date?.trim(), "%Y-%m-%d").ok()?;
    let time = a_time
        .and_then(|time| NaiveTime::parse_from_str(time.trim(), "%H:%M").ok())
        .unwrap_or(DEFAULT_PURCHASE_TIME);
    let offset = Duration::minutes(i64::from(a_tz_offset_min.clamp(-14 * 60, 14 * 60)));
    let ts = date.and_time(time).and_utc() - offset;

    let now = Utc::now();
    (ts <= now + Duration::days(1) && ts >= now - Duration::days(MAX_RECEIPT_AGE_DAYS)).then_some(ts)
}

async fn resolve_currency(
    a_conn: &mut PgConnection,
    a_code: Option<&str>,
    a_country: Option<&str>,
) -> Result<Option<(Uuid, String)>, ApiError>
{
    let by_country = match a_country
    {
        Some("UKR" | "UA") => Some("UAH"),
        Some("IRL" | "IE") => Some("EUR"),
        Some("POL" | "PL") => Some("PLN"),
        Some("GBR" | "GB") => Some("GBP"),
        _ => None,
    };
    let Some(code) = a_code
        .map(|code| code.trim().to_uppercase())
        .filter(|code| code.len() == 3)
        .or_else(|| by_country.map(str::to_string))
    else
    {
        return Ok(None);
    };

    let row = sqlx::query!("SELECT id, code FROM currencies WHERE code = $1", code)
        .fetch_optional(&mut *a_conn)
        .await?;
    Ok(row.map(|row| (row.id, row.code)))
}

async fn match_item(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_line: &CleanLine,
) -> Result<Option<(MatchedItem, LineMatch)>, ApiError>
{
    if let Some(barcode) = a_line.barcode.as_deref()
    {
        let found = sqlx::query_as!(
            MatchedItem,
            r#"
            SELECT i.id, i.name, i.unit AS "unit: ItemUnit"
            FROM items i
            WHERE i.barcode = $2
              AND (i.owner_id = $1 OR (i.owner_id IS NULL AND i.family_id IS NULL)
                   OR i.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1))
            ORDER BY (i.owner_id = $1) DESC
            LIMIT 1
            "#,
            a_user_id,
            barcode
        )
        .fetch_optional(&mut *a_conn)
        .await?;
        if let Some(item) = found
        {
            return Ok(Some((item, LineMatch::Barcode)));
        }
    }

    if let Some(key) = alias_key(&a_line.text)
    {
        let found = sqlx::query_as!(
            MatchedItem,
            r#"
            SELECT i.id, i.name, i.unit AS "unit: ItemUnit"
            FROM item_aliases a
            JOIN items i ON i.id = a.item_id
            WHERE a.user_id = $1 AND a.alias_key = $2
              AND (i.owner_id = $1 OR (i.owner_id IS NULL AND i.family_id IS NULL)
                   OR i.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1))
            "#,
            a_user_id,
            key
        )
        .fetch_optional(&mut *a_conn)
        .await?;
        if let Some(item) = found
        {
            return Ok(Some((item, LineMatch::Alias)));
        }
    }

    let best = sqlx::query_as!(
        ScoredItem,
        r#"
        SELECT
            i.id,
            i.name,
            i.unit AS "unit: ItemUnit",
            GREATEST(similarity(LOWER(i.name), $2), similarity(LOWER(i.name), $3))::float8 AS "score!"
        FROM items i
        WHERE (i.owner_id = $1 OR (i.owner_id IS NULL AND i.family_id IS NULL)
               OR i.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1))
          AND (LOWER(i.name) % $2 OR LOWER(i.name) % $3)
        ORDER BY 4 DESC, (i.owner_id = $1) DESC
        LIMIT 1
        "#,
        a_user_id,
        a_line.name.to_lowercase(),
        a_line.text.to_lowercase()
    )
    .fetch_optional(&mut *a_conn)
    .await?;

    Ok(best.and_then(|best| {
        let item = MatchedItem {
            id: best.id,
            name: best.name,
            unit: best.unit,
        };
        if best.score >= EXACT_ITEM_SCORE
        {
            Some((item, LineMatch::Name))
        }
        else if best.score >= SIMILAR_ITEM_SCORE && item.unit == a_line.unit
        {
            Some((item, LineMatch::Similar))
        }
        else
        {
            None
        }
    }))
}

async fn match_place(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_store_name: &str,
    a_address: &NewPlaceRequest,
) -> Result<(Option<ScoredPlace>, Option<Uuid>, Option<NewPlaceRequest>), ApiError>
{
    let best = sqlx::query_as!(
        ScoredPlace,
        r#"
        SELECT
            p.id,
            p.name,
            GREATEST(
                similarity(LOWER(p.name), $2)::float8,
                CASE
                    WHEN LOWER(p.name) = $2 THEN 1.0
                    WHEN LENGTH(p.name) >= 3 AND (strpos(LOWER(p.name), $2) > 0 OR strpos($2, LOWER(p.name)) > 0)
                        THEN 0.8
                    ELSE 0.0
                END::float8
            ) AS "score!",
            can_edit_scoped(p.owner_id, p.family_id, p.created_by, $1) AS "is_editable!"
        FROM places p
        WHERE p.owner_id = $1 OR p.family_id IN (SELECT family_id FROM family_mems WHERE user_id = $1)
        ORDER BY 3 DESC, (p.owner_id = $1) DESC
        LIMIT 1
        "#,
        a_user_id,
        a_store_name.to_lowercase()
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .filter(|place| place.score >= PLACE_MATCH_SCORE);

    let Some(place) = best
    else
    {
        return Ok((None, None, Some(a_address.clone())));
    };
    if a_address.city.is_none()
    {
        return Ok((Some(place), None, None));
    }

    let branches = sqlx::query_as!(
        ScoredBranch,
        r#"
        SELECT
            a.id,
            COALESCE(similarity(LOWER(st.name), LOWER($2)), 0)::float8 AS "street_score!",
            (a.house_num IS NOT NULL AND LOWER(TRIM(a.house_num)) = LOWER(TRIM($3))) AS "is_same_house!",
            (LOWER(ci.name) = LOWER($4)) AS "is_same_city!",
            (a.street_id IS NULL) AS "is_city_only!"
        FROM place_addrs a
        JOIN cities ci ON ci.id = a.city_id
        LEFT JOIN streets st ON st.id = a.street_id
        WHERE a.place_id = $1
        "#,
        place.id,
        a_address.street.as_deref().unwrap_or_default(),
        a_address.house_num.as_deref().unwrap_or_default(),
        a_address.city.as_deref().unwrap_or_default()
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let has_street_address = a_address.street.is_some() && a_address.house_num.is_some();
    let same_street = branches
        .iter()
        .filter(|branch| has_street_address && branch.is_same_house && branch.street_score >= STREET_MATCH_SCORE)
        .max_by(|left, right| left.street_score.total_cmp(&right.street_score));
    let in_city: Vec<&ScoredBranch> = branches
        .iter()
        .filter(|branch| branch.is_same_city && (branch.is_city_only || !has_street_address))
        .collect();
    let branch = same_street
        .or_else(|| (in_city.len() == 1).then(|| in_city[0]))
        .map(|branch| branch.id);

    let new_branch = (branch.is_none() && place.is_editable).then(|| NewPlaceRequest {
        place_id: Some(place.id),
        name: place.name.clone(),
        ..a_address.clone()
    });

    Ok((Some(place), branch, new_branch))
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn raw(a_text: &str, a_amount: f64) -> RawLine
    {
        RawLine {
            text: a_text.into(),
            name: a_text.into(),
            kind: "food".into(),
            unit: "piece".into(),
            quantity: 1.0,
            unit_price: Some(a_amount),
            amount: a_amount,
            barcode: None,
        }
    }

    #[test]
    fn deal_lines_are_split_between_the_same_items()
    {
        let (lines, leftover) = fold_line_discounts(vec![
            raw("AVONMORE GOLD", 2.25),
            raw("RED BULL", 2.70),
            raw("AVONMORE GOLD", 2.25),
            raw("SAVER DEAL !", -1.50),
            raw("SUSHI", 7.75),
        ]);
        let amounts: Vec<f64> = lines.iter().map(|line| line.amount).collect();
        assert_eq!(amounts, vec![1.5, 2.7, 1.5, 7.75]);
        assert_eq!(lines[0].unit_price, Some(1.5));
        assert_eq!(leftover, 0);
    }

    #[test]
    fn unmatched_discounts_become_receipt_discounts()
    {
        let (lines, leftover) = fold_line_discounts(vec![raw("COUPON", -1.0), raw("BREAD", 0.30), raw("PROMO", -0.51)]);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].amount, 0.0);
        assert_eq!(leftover, 121);

        let (odd, _) = fold_line_discounts(vec![raw("TEA", 1.00), raw("TEA", 1.00), raw("2 FOR", -0.51)]);
        let total: f64 = odd.iter().map(|line| line.amount).sum();
        assert!((total - 1.49).abs() < 1e-9);

        let discount = receipt_discount(&[RawDiscount {
            text: "DISCOUNT VOUCHER".into(),
            amount: 5.0,
        }]);
        assert_eq!(discount.to_string(), "5.00");
    }

    #[test]
    fn lines_are_cleaned_and_bounded()
    {
        let line = clean_line(RawLine {
            text: "  МОЛОКО\tГАЛИЧ  2.5% ".into(),
            name: "".into(),
            kind: "food".into(),
            unit: "kilogram".into(),
            quantity: 0.51249,
            unit_price: Some(89.9),
            amount: 46.071,
            barcode: Some("4820024700016".into()),
        })
        .unwrap();
        assert_eq!(line.text, "МОЛОКО ГАЛИЧ 2.5%");
        assert_eq!(line.name, line.text);
        assert_eq!(line.qty.to_string(), "0.512");
        assert_eq!(line.amount.to_string(), "46.07");
        assert_eq!(line.unit, ItemUnit::Kilogram);
        assert_eq!(line.kind, ItemKind::Food);

        assert!(clean_line(RawLine {
            text: "Знижка".into(),
            name: "Знижка".into(),
            kind: "product".into(),
            unit: "piece".into(),
            quantity: 1.0,
            unit_price: None,
            amount: -5.0,
            barcode: None,
        })
        .is_none());
    }

    #[test]
    fn purchase_time_uses_the_client_offset()
    {
        let ts = purchase_ts(Some(&Utc::now().date_naive().to_string()), Some("00:30"), 180);
        if let Some(ts) = ts
        {
            assert_eq!(ts.format("%H:%M").to_string(), "21:30");
        }
        assert!(purchase_ts(Some("1999-01-01"), None, 0).is_none());
        assert!(purchase_ts(Some("not a date"), None, 0).is_none());
    }

    #[test]
    fn alias_keys_ignore_case_and_spacing()
    {
        assert_eq!(alias_key("  Хліб   БІЛИЙ "), Some("хліб білий".to_string()));
        assert_eq!(alias_key("   "), None);
    }
}
