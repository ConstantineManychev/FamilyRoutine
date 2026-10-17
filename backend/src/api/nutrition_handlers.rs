use std::collections::{BTreeSet, HashMap};

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    ActivityLevel, CopyMealsDto, CopyMealsRequest, DayMealDto, DishDto, DishIngredientDto, DishQuery, GoalMode,
    ItemKind, ItemUnit, MacrosDto, MealEntryDto, MealSource, NewMealEntryRequest, NormGap, NutritionDayDto,
    NutritionDayQuery, NutritionGoalDto, NutritionNormDto, PersonNormDto, PersonNormQuery, PersonQuery,
    QuickEntryRequest, RecentFoodDto, RoutineStatus, SaveDishRequest, SaveGoalRequest, Sex, StatusMarkDto,
    UpdateMealEntryRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::stock_handlers::{
    consume_batch, consume_item, entry_store, load_batch, require_visible_batch, Consumer,
};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text, contains_pattern};
use crate::security::profile_access::{acting_for, is_editor, profile_access, require_editor};
use crate::services::nutrition::{
    amount, clean_custom, clean_goal, daily_norm, dish_math, for_grams, is_child, portion_grams, sum, BodyProfile,
    GoalSettings, Ingredient,
};
use crate::state::AppState;

const MAX_DISHES_PER_USER: i64 = 300;
pub const MAX_INGREDIENTS: usize = 50;
const MAX_DISH_NAME_LEN: usize = 100;
const MAX_NOTE_LEN: usize = 500;
const MAX_TITLE_LEN: usize = 200;
pub const MAX_INGREDIENT_G: i64 = 20_000;
pub const MAX_COOKED_G: i64 = 100_000;
pub const COOKED_RATIO_LIMIT: i64 = 10;
const MAX_SERVING_G: i64 = 10_000;
const MAX_SERVINGS: i32 = 100;
const MAX_ENTRY_G: i64 = 10_000;
const MAX_PORTIONS: i64 = 50;
const PORTIONS_SCALE: u32 = 2;
const MAX_ENTRIES_PER_DAY: i64 = 100;
const MAX_QUICK_KCAL: i64 = 10_000;
const MAX_QUICK_GRAMS: i64 = 1_000;
const MAX_FUTURE_DAYS: i64 = 7;
const MAX_PAST_DAYS: i64 = 3_660;
const MAX_TZ_OFFSET_MIN: i32 = 840;
const RECENT_LIMIT: i64 = 30;
const MAX_MARK_DAY_GAP: i64 = 1;
const COPY_BACK_HOURS: i64 = 24;
const COPY_WINDOW_HOURS: i64 = 2;
const RECENT_WORKOUT_DAYS: i64 = 7;

struct DishRow
{
    id: Uuid,
    owner_id: Uuid,
    name: String,
    note: Option<String>,
    cooked_g: Option<Decimal>,
    serving_g: Option<Decimal>,
    servings: Option<i32>,
    is_shared: bool,
    owner_name: Option<String>,
    updated_ts: DateTime<Utc>,
}

struct IngredientRow
{
    dish_id: Uuid,
    item_id: Uuid,
    item_name: String,
    unit: ItemUnit,
    piece_g: Option<Decimal>,
    grams: Decimal,
    kcal: Option<Decimal>,
    prot: Option<Decimal>,
    fat: Option<Decimal>,
    carb: Option<Decimal>,
}

struct CleanDish
{
    name: String,
    note: Option<String>,
    cooked_g: Option<Decimal>,
    serving_g: Option<Decimal>,
    servings: Option<i32>,
    is_shared: bool,
    item_ids: Vec<Uuid>,
    grams: Vec<Decimal>,
}

struct EntryRow
{
    id: Uuid,
    eaten_on: NaiveDate,
    source: MealSource,
    item_id: Option<Uuid>,
    dish_id: Option<Uuid>,
    title: Option<String>,
    grams: Option<Decimal>,
    portions: Option<Decimal>,
    portion_g: Option<Decimal>,
    is_ml: bool,
    kcal_100: Option<Decimal>,
    prot_100: Option<Decimal>,
    fat_100: Option<Decimal>,
    carb_100: Option<Decimal>,
    kcal: Decimal,
    prot: Decimal,
    fat: Decimal,
    carb: Decimal,
    status_mark_id: Option<Uuid>,
    batch_id: Option<Uuid>,
    stock_short: Option<Decimal>,
    created_ts: DateTime<Utc>,
}

struct Snapshot
{
    source: MealSource,
    item_id: Option<Uuid>,
    dish_id: Option<Uuid>,
    batch_id: Option<Uuid>,
    title: Option<String>,
    grams: Option<Decimal>,
    portions: Option<Decimal>,
    portion_g: Option<Decimal>,
    is_ml: bool,
    per_100: Option<MacrosDto>,
    total: MacrosDto,
}

impl EntryRow
{
    fn per_100(&self) -> Option<MacrosDto>
    {
        Some(MacrosDto {
            kcal: self.kcal_100?.normalize(),
            prot: self.prot_100?.normalize(),
            fat: self.fat_100?.normalize(),
            carb: self.carb_100?.normalize(),
        })
    }
}

impl From<EntryRow> for MealEntryDto
{
    fn from(a_row: EntryRow) -> Self
    {
        Self {
            per_100: a_row.per_100(),
            id: a_row.id,
            date: a_row.eaten_on,
            source: a_row.source,
            item_id: a_row.item_id,
            dish_id: a_row.dish_id,
            title: a_row.title,
            grams: a_row.grams.map(|value| value.normalize()),
            portions: a_row.portions.map(|value| value.normalize()),
            portion_g: a_row.portion_g.map(|value| value.normalize()),
            is_ml: a_row.is_ml,
            total: MacrosDto {
                kcal: a_row.kcal.normalize(),
                prot: a_row.prot.normalize(),
                fat: a_row.fat.normalize(),
                carb: a_row.carb.normalize(),
            },
            status_mark_id: a_row.status_mark_id,
            batch_id: a_row.batch_id,
            stock_short: a_row.stock_short.map(|value| value.normalize()),
            created_ts: a_row.created_ts,
        }
    }
}

pub fn item_per_100(
    a_kcal: Option<Decimal>,
    a_prot: Option<Decimal>,
    a_fat: Option<Decimal>,
    a_carb: Option<Decimal>,
) -> Option<MacrosDto>
{
    a_kcal.map(|kcal| MacrosDto {
        kcal: kcal.normalize(),
        prot: a_prot.unwrap_or_default().normalize(),
        fat: a_fat.unwrap_or_default().normalize(),
        carb: a_carb.unwrap_or_default().normalize(),
    })
}

pub fn bounded(a_value: Decimal, a_max: i64, a_field: &'static str) -> Result<Decimal, ApiError>
{
    let value = amount(a_value);
    if value <= Decimal::ZERO || value > Decimal::from(a_max)
    {
        return Err(ApiError::Validation(a_field));
    }
    Ok(value)
}

fn non_negative(a_value: Option<Decimal>, a_max: i64, a_field: &'static str) -> Result<Decimal, ApiError>
{
    let value = amount(a_value.unwrap_or_default());
    if value < Decimal::ZERO || value > Decimal::from(a_max)
    {
        return Err(ApiError::Validation(a_field));
    }
    Ok(value)
}

fn check_date(a_date: NaiveDate, a_field: &'static str) -> Result<NaiveDate, ApiError>
{
    let today = Utc::now().date_naive();
    if a_date > today + Duration::days(MAX_FUTURE_DAYS) || a_date < today - Duration::days(MAX_PAST_DAYS)
    {
        return Err(ApiError::Validation(a_field));
    }
    Ok(a_date)
}

fn build_dish(a_user_id: Uuid, a_row: DishRow, a_ingredients: Vec<IngredientRow>) -> DishDto
{
    let inputs: Vec<Ingredient> = a_ingredients
        .iter()
        .map(|row| Ingredient {
            per_100: item_per_100(row.kcal, row.prot, row.fat, row.carb),
            grams: row.grams,
        })
        .collect();
    let math = dish_math(&inputs, a_row.cooked_g, a_row.serving_g, a_row.servings);
    let ingredients = a_ingredients
        .into_iter()
        .zip(inputs)
        .map(|(row, input)| DishIngredientDto {
            item_id: row.item_id,
            item_name: row.item_name,
            unit: row.unit,
            piece_g: row.piece_g.map(|value| value.normalize()),
            grams: row.grams.normalize(),
            total: input
                .per_100
                .map(|per_100| for_grams(per_100, row.grams))
                .unwrap_or_default(),
            per_100: input.per_100,
        })
        .collect::<Vec<_>>();

    DishDto {
        id: a_row.id,
        name: a_row.name,
        note: a_row.note,
        raw_g: math.raw_g,
        cooked_g: math.cooked_g,
        is_cooked_set: a_row.cooked_g.is_some(),
        serving_g: a_row.serving_g.map(|value| value.normalize()),
        servings: a_row.servings,
        portion_g: math.portion_g,
        per_100: math.per_100,
        total: math.total,
        ingredient_count: ingredients.len(),
        missing_count: math.missing_count,
        is_shared: a_row.is_shared,
        is_editable: a_row.owner_id == a_user_id,
        owner_name: a_row.owner_name,
        updated_ts: a_row.updated_ts,
        ingredients,
    }
}

async fn query_dishes(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_id: Option<Uuid>,
    a_pattern: Option<&str>,
) -> Result<Vec<DishDto>, ApiError>
{
    let rows = sqlx::query_as!(
        DishRow,
        r#"
        SELECT
            d.id,
            d.owner_id,
            d.name,
            d.note,
            d.cooked_g,
            d.serving_g,
            d.servings,
            d.is_shared,
            d.updated_ts,
            CASE WHEN d.owner_id <> $1 THEN u.first_name || ' ' || u.last_name END AS owner_name
        FROM dishes d
        JOIN users u ON u.id = d.owner_id
        WHERE ($2::uuid IS NULL OR d.id = $2)
          AND ($3::text IS NULL OR d.name ILIKE $3)
          AND (
              d.owner_id = $1
              OR (d.is_shared AND EXISTS (
                  SELECT 1
                  FROM family_mems mine
                  JOIN family_mems theirs ON theirs.family_id = mine.family_id
                  WHERE mine.user_id = $1 AND theirs.user_id = d.owner_id
              ))
          )
        ORDER BY (d.owner_id = $1) DESC, LOWER(d.name), d.id
        "#,
        a_user_id,
        a_id,
        a_pattern
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let ids: Vec<Uuid> = rows.iter().map(|row| row.id).collect();
    let ingredient_rows = sqlx::query_as!(
        IngredientRow,
        r#"
        SELECT
            di.dish_id,
            di.item_id,
            i.name AS item_name,
            i.unit AS "unit: ItemUnit",
            i.piece_g,
            di.grams,
            i.kcal,
            i.prot,
            i.fat,
            i.carb
        FROM dish_ingredients di
        JOIN items i ON i.id = di.item_id
        WHERE di.dish_id = ANY($1)
        ORDER BY di.dish_id, di.position
        "#,
        &ids
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let mut by_dish: HashMap<Uuid, Vec<IngredientRow>> = HashMap::new();
    for row in ingredient_rows
    {
        by_dish.entry(row.dish_id).or_default().push(row);
    }

    Ok(rows
        .into_iter()
        .map(|row| {
            let ingredients = by_dish.remove(&row.id).unwrap_or_default();
            build_dish(a_user_id, row, ingredients)
        })
        .collect())
}

pub async fn load_dish(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<DishDto, ApiError>
{
    query_dishes(a_conn, a_user_id, Some(a_id), None)
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

fn clean_dish(a_req: SaveDishRequest) -> Result<CleanDish, ApiError>
{
    let name = clean_text(&a_req.name, 1, MAX_DISH_NAME_LEN, "name")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    if a_req.ingredients.is_empty() || a_req.ingredients.len() > MAX_INGREDIENTS
    {
        return Err(ApiError::Validation("ingredients"));
    }

    let mut item_ids = Vec::with_capacity(a_req.ingredients.len());
    let mut grams = Vec::with_capacity(a_req.ingredients.len());
    for ingredient in &a_req.ingredients
    {
        item_ids.push(ingredient.item_id);
        grams.push(bounded(ingredient.grams, MAX_INGREDIENT_G, "ingredients.grams")?);
    }
    let raw_g: Decimal = grams.iter().sum();

    let cooked_g = match a_req.cooked_g
    {
        Some(value) =>
        {
            let cooked = bounded(value, MAX_COOKED_G, "cooked_g")?;
            let ratio = Decimal::from(COOKED_RATIO_LIMIT);
            if cooked * ratio < raw_g || cooked > raw_g * ratio
            {
                return Err(ApiError::Validation("cooked_g"));
            }
            Some(cooked)
        }
        None => None,
    };
    if a_req.serving_g.is_some() && a_req.servings.is_some()
    {
        return Err(ApiError::Validation("servings"));
    }
    let serving_g = a_req
        .serving_g
        .map(|value| bounded(value, MAX_SERVING_G, "serving_g"))
        .transpose()?;
    if a_req
        .servings
        .is_some_and(|servings| !(1..=MAX_SERVINGS).contains(&servings))
    {
        return Err(ApiError::Validation("servings"));
    }

    Ok(CleanDish {
        name,
        note,
        cooked_g,
        serving_g,
        servings: a_req.servings,
        is_shared: a_req.is_shared,
        item_ids,
        grams,
    })
}

pub async fn require_food_items(a_conn: &mut PgConnection, a_item_ids: &[Uuid]) -> Result<(), ApiError>
{
    let distinct: Vec<Uuid> = a_item_ids
        .iter()
        .copied()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let found = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM items WHERE id = ANY($1) AND type = 'food'"#,
        &distinct
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if usize::try_from(found).ok() != Some(distinct.len())
    {
        return Err(ApiError::Validation("ingredients.item_id"));
    }
    Ok(())
}

async fn insert_ingredients(a_conn: &mut PgConnection, a_dish_id: Uuid, a_dish: &CleanDish) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        INSERT INTO dish_ingredients (dish_id, position, item_id, grams)
        SELECT $1, (t.ord - 1)::smallint, t.item_id, t.grams
        FROM UNNEST($2::uuid[], $3::numeric[]) WITH ORDINALITY AS t(item_id, grams, ord)
        "#,
        a_dish_id,
        &a_dish.item_ids,
        &a_dish.grams
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

pub async fn list_dishes(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<DishQuery>,
) -> Result<Json<Vec<DishDto>>, ApiError>
{
    let pattern = contains_pattern(a_query.q.as_deref())?;
    let mut conn = a_state.db.acquire().await?;
    let mut dishes = query_dishes(&mut conn, a_user.user_id, None, pattern.as_deref()).await?;
    for dish in &mut dishes
    {
        dish.ingredients.clear();
    }
    Ok(Json(dishes))
}

pub async fn get_dish(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<DishDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_dish(&mut conn, a_user.user_id, a_id).await.map(Json)
}

pub async fn create_dish(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveDishRequest>,
) -> Result<(StatusCode, Json<DishDto>), ApiError>
{
    let dish = clean_dish(a_req)?;
    let mut tx = a_state.db.begin().await?;
    sqlx::query!("SELECT id FROM users WHERE id = $1 FOR UPDATE", a_user.user_id)
        .fetch_one(&mut *tx)
        .await?;
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM dishes WHERE owner_id = $1"#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_DISHES_PER_USER
    {
        return Err(ApiError::Conflict("TOO_MANY_DISHES"));
    }
    require_food_items(&mut tx, &dish.item_ids).await?;

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO dishes (owner_id, name, note, cooked_g, serving_g, servings, is_shared)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id
        "#,
        a_user.user_id,
        dish.name,
        dish.note,
        dish.cooked_g,
        dish.serving_g,
        dish.servings,
        dish.is_shared
    )
    .fetch_one(&mut *tx)
    .await?;
    insert_ingredients(&mut tx, id, &dish).await?;

    let saved = load_dish(&mut tx, a_user.user_id, id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(saved)))
}

pub async fn update_dish(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveDishRequest>,
) -> Result<Json<DishDto>, ApiError>
{
    let dish = clean_dish(a_req)?;
    let mut tx = a_state.db.begin().await?;
    let updated = sqlx::query!(
        r#"
        UPDATE dishes
        SET name = $3, note = $4, cooked_g = $5, serving_g = $6, servings = $7, is_shared = $8, updated_ts = NOW()
        WHERE id = $1 AND owner_id = $2
        "#,
        a_id,
        a_user.user_id,
        dish.name,
        dish.note,
        dish.cooked_g,
        dish.serving_g,
        dish.servings,
        dish.is_shared
    )
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    require_food_items(&mut tx, &dish.item_ids).await?;

    sqlx::query!("DELETE FROM dish_ingredients WHERE dish_id = $1", a_id)
        .execute(&mut *tx)
        .await?;
    insert_ingredients(&mut tx, a_id, &dish).await?;

    let saved = load_dish(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(saved))
}

pub async fn delete_dish(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM dishes WHERE id = $1 AND owner_id = $2",
        a_id,
        a_user.user_id
    )
    .execute(&a_state.db)
    .await?;
    if deleted.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

fn resolve_amount(
    a_grams: Option<Decimal>,
    a_portions: Option<Decimal>,
    a_portion_g: Option<Decimal>,
) -> Result<(Decimal, Option<Decimal>), ApiError>
{
    match (a_grams, a_portions)
    {
        (None, Some(portions)) =>
        {
            let portion_g = a_portion_g.ok_or(ApiError::Validation("portions"))?;
            let portions = portions.round_dp(PORTIONS_SCALE).normalize();
            if portions <= Decimal::ZERO || portions > Decimal::from(MAX_PORTIONS)
            {
                return Err(ApiError::Validation("portions"));
            }
            let grams = portion_grams(portions, portion_g);
            if grams <= Decimal::ZERO || grams > Decimal::from(MAX_ENTRY_G)
            {
                return Err(ApiError::Validation("portions"));
            }
            Ok((grams, Some(portions)))
        }
        (Some(grams), None) => Ok((bounded(grams, MAX_ENTRY_G, "grams")?, None)),
        _ => Err(ApiError::Validation("grams")),
    }
}

fn quick_snapshot(a_quick: &QuickEntryRequest) -> Result<Snapshot, ApiError>
{
    let total = MacrosDto {
        kcal: non_negative(Some(a_quick.kcal), MAX_QUICK_KCAL, "quick.kcal")?,
        prot: non_negative(a_quick.prot, MAX_QUICK_GRAMS, "quick.prot")?,
        fat: non_negative(a_quick.fat, MAX_QUICK_GRAMS, "quick.fat")?,
        carb: non_negative(a_quick.carb, MAX_QUICK_GRAMS, "quick.carb")?,
    };
    Ok(Snapshot {
        source: MealSource::Quick,
        item_id: None,
        dish_id: None,
        batch_id: None,
        title: clean_optional_text(a_quick.title.as_deref(), MAX_TITLE_LEN, "quick.title")?,
        grams: None,
        portions: None,
        portion_g: None,
        is_ml: false,
        per_100: None,
        total,
    })
}

async fn item_snapshot(
    a_conn: &mut PgConnection,
    a_item_id: Uuid,
    a_grams: Option<Decimal>,
    a_portions: Option<Decimal>,
) -> Result<Snapshot, ApiError>
{
    let item = sqlx::query!(
        r#"
        SELECT name, type AS "kind: ItemKind", unit AS "unit: ItemUnit", kcal, prot, fat, carb, piece_g
        FROM items
        WHERE id = $1
        "#,
        a_item_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .filter(|item| item.kind == ItemKind::Food)
    .ok_or(ApiError::Validation("item_id"))?;
    let per_100 = item_per_100(item.kcal, item.prot, item.fat, item.carb).ok_or(ApiError::Validation("nutrition"))?;
    let (grams, portions) = resolve_amount(a_grams, a_portions, item.piece_g)?;

    Ok(Snapshot {
        source: MealSource::Item,
        item_id: Some(a_item_id),
        dish_id: None,
        batch_id: None,
        title: Some(item.name),
        grams: Some(grams),
        portions,
        portion_g: portions.and(item.piece_g),
        is_ml: item.unit == ItemUnit::Liter,
        per_100: Some(per_100),
        total: for_grams(per_100, grams),
    })
}

async fn dish_snapshot(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_dish_id: Uuid,
    a_batch_id: Option<Uuid>,
    a_grams: Option<Decimal>,
    a_portions: Option<Decimal>,
) -> Result<Snapshot, ApiError>
{
    let dish = match load_dish(a_conn, a_user_id, a_dish_id).await
    {
        Err(ApiError::NotFound) => return Err(ApiError::Validation("dish_id")),
        other => other?,
    };
    let (grams, portions) = resolve_amount(a_grams, a_portions, dish.portion_g)?;
    let (title, per_100) = match a_batch_id
    {
        Some(batch_id) =>
        {
            require_visible_batch(a_conn, batch_id, a_user_id).await?;
            let batch = load_batch(a_conn, a_user_id, batch_id).await?;
            if batch.dish_id != Some(a_dish_id)
            {
                return Err(ApiError::Validation("batch_id"));
            }
            (batch.title, batch.per_100)
        }
        None => (dish.name, dish.per_100),
    };

    Ok(Snapshot {
        source: MealSource::Dish,
        item_id: None,
        dish_id: Some(a_dish_id),
        batch_id: a_batch_id,
        title: Some(title),
        grams: Some(grams),
        portions,
        portion_g: portions.and(dish.portion_g),
        is_ml: false,
        per_100: Some(per_100),
        total: for_grams(per_100, grams),
    })
}

async fn entry_owner(a_conn: &mut PgConnection, a_viewer_id: Uuid, a_id: Uuid) -> Result<Uuid, ApiError>
{
    let owner_id = sqlx::query_scalar!("SELECT user_id FROM meal_entries WHERE id = $1", a_id)
        .fetch_optional(&mut *a_conn)
        .await?
        .ok_or(ApiError::NotFound)?;
    require_editor(a_conn, a_viewer_id, owner_id).await?;
    Ok(owner_id)
}

async fn take_from_stock(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_entry_id: Uuid,
    a_item_id: Option<Uuid>,
    a_batch_id: Option<Uuid>,
    a_grams: Option<Decimal>,
) -> Result<Option<Decimal>, ApiError>
{
    let Some(grams) = a_grams
    else
    {
        return Ok(None);
    };
    let short = match (a_item_id, a_batch_id)
    {
        (Some(item_id), None) =>
        {
            let store = entry_store(a_conn, a_entry_id, a_user_id).await?;
            sqlx::query!("DELETE FROM stock_moves WHERE meal_entry_id = $1", a_entry_id)
                .execute(&mut *a_conn)
                .await?;
            consume_item(a_conn, store, item_id, grams, Consumer::Entry(a_entry_id), a_user_id).await?
        }
        (None, Some(batch_id)) =>
        {
            sqlx::query!("DELETE FROM stock_moves WHERE meal_entry_id = $1", a_entry_id)
                .execute(&mut *a_conn)
                .await?;
            consume_batch(a_conn, batch_id, grams, a_entry_id, a_user_id).await?
        }
        _ => return Ok(None),
    };
    let short = short.min(grams);
    sqlx::query!(
        "UPDATE meal_entries SET stock_short = $2 WHERE id = $1",
        a_entry_id,
        short
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(Some(short))
}

async fn require_day_capacity(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_date: NaiveDate,
    a_added: i64,
) -> Result<(), ApiError>
{
    sqlx::query!("SELECT id FROM users WHERE id = $1 FOR UPDATE", a_user_id)
        .fetch_one(&mut *a_conn)
        .await?;
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM meal_entries WHERE user_id = $1 AND eaten_on = $2"#,
        a_user_id,
        a_date
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if count + a_added > MAX_ENTRIES_PER_DAY
    {
        return Err(ApiError::Conflict("TOO_MANY_ENTRIES"));
    }
    Ok(())
}

pub async fn meal_mark_start(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_mark_id: Uuid,
) -> Result<DateTime<Utc>, ApiError>
{
    sqlx::query_scalar!(
        "SELECT start_ts FROM status_marks WHERE id = $1 AND user_id = $2 AND status = 'meal'",
        a_mark_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::Validation("status_mark_id"))
}

pub async fn require_meal_mark(a_conn: &mut PgConnection, a_user_id: Uuid, a_mark_id: Uuid) -> Result<(), ApiError>
{
    meal_mark_start(a_conn, a_user_id, a_mark_id).await.map(|_| ())
}

fn require_near(a_date: NaiveDate, a_mark_start: DateTime<Utc>) -> Result<(), ApiError>
{
    if (a_date - a_mark_start.date_naive()).num_days().abs() > MAX_MARK_DAY_GAP
    {
        return Err(ApiError::Validation("date"));
    }
    Ok(())
}

pub async fn mark_entries(
    a_conn: &mut PgConnection,
    a_owner_id: Uuid,
    a_mark_id: Uuid,
) -> Result<Vec<MealEntryDto>, ApiError>
{
    let rows = sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, eaten_on, source AS "source: MealSource", item_id, dish_id, title,
               grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               status_mark_id, batch_id, stock_short, created_ts
        FROM meal_entries
        WHERE user_id = $1 AND status_mark_id = $2
        ORDER BY created_ts, id
        "#,
        a_owner_id,
        a_mark_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(rows.into_iter().map(MealEntryDto::from).collect())
}

pub async fn create_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<NewMealEntryRequest>,
) -> Result<(StatusCode, Json<MealEntryDto>), ApiError>
{
    let date = check_date(a_req.date, "date")?;
    let mut tx = a_state.db.begin().await?;
    let person_id = acting_for(&mut tx, a_user.user_id, a_req.person_id).await?;
    let snapshot = match (a_req.item_id, a_req.dish_id, a_req.quick.as_ref())
    {
        (Some(item_id), None, None) if a_req.batch_id.is_none() =>
        {
            item_snapshot(&mut tx, item_id, a_req.grams, a_req.portions).await?
        }
        (None, Some(dish_id), None) =>
        {
            dish_snapshot(
                &mut tx,
                a_user.user_id,
                dish_id,
                a_req.batch_id,
                a_req.grams,
                a_req.portions,
            )
            .await?
        }
        (None, None, Some(quick)) if a_req.grams.is_none() && a_req.portions.is_none() && a_req.batch_id.is_none() =>
        {
            quick_snapshot(quick)?
        }
        _ => return Err(ApiError::Validation("source")),
    };
    let mark_start = meal_mark_start(&mut tx, person_id, a_req.status_mark_id).await?;
    require_near(date, mark_start)?;
    require_day_capacity(&mut tx, person_id, date, 1).await?;

    let per_100 = snapshot.per_100;
    let row = sqlx::query_as!(
        EntryRow,
        r#"
        INSERT INTO meal_entries (
            user_id, eaten_on, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
            kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb, status_mark_id, batch_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20)
        RETURNING id, eaten_on, source AS "source: MealSource", item_id, dish_id, title,
                  grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
                  status_mark_id, batch_id, stock_short, created_ts
        "#,
        person_id,
        date,
        snapshot.source as MealSource,
        snapshot.item_id,
        snapshot.dish_id,
        snapshot.title,
        snapshot.grams,
        snapshot.portions,
        snapshot.portion_g,
        snapshot.is_ml,
        per_100.map(|value| value.kcal),
        per_100.map(|value| value.prot),
        per_100.map(|value| value.fat),
        per_100.map(|value| value.carb),
        snapshot.total.kcal,
        snapshot.total.prot,
        snapshot.total.fat,
        snapshot.total.carb,
        a_req.status_mark_id,
        snapshot.batch_id
    )
    .fetch_one(&mut *tx)
    .await?;
    let mut entry = MealEntryDto::from(row);
    if entry.source != MealSource::Dish || entry.batch_id.is_some()
    {
        entry.stock_short = take_from_stock(
            &mut tx,
            a_user.user_id,
            entry.id,
            entry.item_id,
            entry.batch_id,
            entry.grams,
        )
        .await?
        .map(|value| value.normalize());
    }

    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(entry)))
}

pub async fn update_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<UpdateMealEntryRequest>,
) -> Result<Json<MealEntryDto>, ApiError>
{
    let date = check_date(a_req.date, "date")?;
    let mut tx = a_state.db.begin().await?;
    let owner_id = entry_owner(&mut tx, a_user.user_id, a_id).await?;
    let current = sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, eaten_on, source AS "source: MealSource", item_id, dish_id, title,
               grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               status_mark_id, batch_id, stock_short, created_ts
        FROM meal_entries
        WHERE id = $1 AND user_id = $2
        FOR UPDATE
        "#,
        a_id,
        owner_id
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(ApiError::NotFound)?;

    let (title, grams, portions, total) = match (current.source, a_req.quick.as_ref())
    {
        (MealSource::Quick, Some(quick)) if a_req.grams.is_none() && a_req.portions.is_none() =>
        {
            let snapshot = quick_snapshot(quick)?;
            (snapshot.title, None, None, snapshot.total)
        }
        (MealSource::Item | MealSource::Dish, None) =>
        {
            let per_100 = current.per_100().ok_or(ApiError::Validation("source"))?;
            let (grams, portions) = resolve_amount(a_req.grams, a_req.portions, current.portion_g)?;
            (current.title.clone(), Some(grams), portions, for_grams(per_100, grams))
        }
        _ => return Err(ApiError::Validation("source")),
    };
    let mark_id = match a_req.status_mark_id
    {
        Some(mark_id) =>
        {
            let mark_start = meal_mark_start(&mut tx, owner_id, mark_id).await?;
            require_near(date, mark_start)?;
            Some(mark_id)
        }
        None => current.status_mark_id,
    };
    if date != current.eaten_on
    {
        require_day_capacity(&mut tx, owner_id, date, 1).await?;
    }

    let row = sqlx::query_as!(
        EntryRow,
        r#"
        UPDATE meal_entries
        SET eaten_on = $2, status_mark_id = $3, title = $4, grams = $5, portions = $6, kcal = $7, prot = $8,
            fat = $9, carb = $10
        WHERE id = $1
        RETURNING id, eaten_on, source AS "source: MealSource", item_id, dish_id, title,
                  grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
                  status_mark_id, batch_id, stock_short, created_ts
        "#,
        a_id,
        date,
        mark_id,
        title,
        grams,
        portions,
        total.kcal,
        total.prot,
        total.fat,
        total.carb
    )
    .fetch_one(&mut *tx)
    .await?;
    let mut entry = MealEntryDto::from(row);
    if current.stock_short.is_some() && grams != current.grams
    {
        entry.stock_short = take_from_stock(
            &mut tx,
            a_user.user_id,
            entry.id,
            entry.item_id,
            entry.batch_id,
            entry.grams,
        )
        .await?
        .map(|value| value.normalize());
    }

    tx.commit().await?;
    Ok(Json(entry))
}

pub async fn delete_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let owner_id = entry_owner(&mut conn, a_user.user_id, a_id).await?;
    let deleted = sqlx::query!(
        "DELETE FROM meal_entries WHERE id = $1 AND user_id = $2",
        a_id,
        owner_id
    )
    .execute(&mut *conn)
    .await?;
    if deleted.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

pub async fn nutrition_day(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<NutritionDayQuery>,
) -> Result<Json<NutritionDayDto>, ApiError>
{
    if a_query.tz_offset_min.abs() > MAX_TZ_OFFSET_MIN
    {
        return Err(ApiError::Validation("tz_offset_min"));
    }
    let date = a_query.date;
    let day_start = date.and_hms_opt(0, 0, 0).ok_or(ApiError::Validation("date"))?.and_utc()
        - Duration::minutes(i64::from(a_query.tz_offset_min));
    let day_end = day_start + Duration::days(1);
    let mut conn = a_state.db.acquire().await?;
    let person_id = a_query.person_id.unwrap_or(a_user.user_id);
    let can_edit = is_editor(&mut conn, a_user.user_id, person_id).await?;

    let rows = sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, eaten_on, source AS "source: MealSource", item_id, dish_id, title,
               grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               status_mark_id, batch_id, stock_short, created_ts
        FROM meal_entries
        WHERE user_id = $1 AND eaten_on = $2
        ORDER BY created_ts, id
        "#,
        person_id,
        date
    )
    .fetch_all(&mut *conn)
    .await?;
    let entries: Vec<MealEntryDto> = rows.into_iter().map(MealEntryDto::from).collect();
    let linked: Vec<Uuid> = entries.iter().filter_map(|entry| entry.status_mark_id).collect();
    let marks = sqlx::query_as!(
        StatusMarkDto,
        r#"
        SELECT id, status AS "status: RoutineStatus", note, start_ts, end_ts
        FROM status_marks
        WHERE user_id = $1 AND status = 'meal' AND ((start_ts >= $2 AND start_ts < $3) OR id = ANY($4))
        ORDER BY start_ts
        "#,
        person_id,
        day_start,
        day_end,
        &linked
    )
    .fetch_all(&mut *conn)
    .await?;
    let meals: Vec<DayMealDto> = marks
        .into_iter()
        .map(|mark| {
            let entries: Vec<MealEntryDto> = entries
                .iter()
                .filter(|entry| entry.status_mark_id == Some(mark.id))
                .cloned()
                .collect();
            DayMealDto {
                total: sum(entries.iter().map(|entry| entry.total)),
                entries,
                mark,
            }
        })
        .collect();
    let unlinked: Vec<MealEntryDto> = entries
        .iter()
        .filter(|entry| !meals.iter().any(|meal| entry.status_mark_id == Some(meal.mark.id)))
        .cloned()
        .collect();
    let (norm, norm_gaps) = load_norm(&mut conn, person_id, date, day_end).await?;

    let workout_kcal = sqlx::query_scalar!(
        r#"
        SELECT COALESCE(SUM(kcal), 0)::numeric AS "kcal!"
        FROM workout_sessions
        WHERE user_id = $1 AND finished_ts IS NOT NULL AND started_ts >= $2 AND started_ts < $3
        "#,
        person_id,
        day_start,
        day_end
    )
    .fetch_one(&mut *conn)
    .await?;

    Ok(Json(NutritionDayDto {
        date,
        total: sum(entries.iter().map(|entry| entry.total)),
        meals,
        unlinked_total: sum(unlinked.iter().map(|entry| entry.total)),
        unlinked,
        norm,
        norm_gaps,
        workout_kcal: workout_kcal.round_dp(0).normalize(),
        person_id,
        can_edit,
    }))
}

struct StoredGoal
{
    mode: GoalMode,
    pace_kg: Option<Decimal>,
    target_kg: Option<Decimal>,
    is_custom: bool,
    custom: Option<MacrosDto>,
}

impl StoredGoal
{
    fn settings(&self) -> GoalSettings
    {
        GoalSettings {
            mode: self.mode,
            pace_kg: self.pace_kg,
            target_kg: self.target_kg,
            custom: self.custom.filter(|_| self.is_custom),
        }
    }
}

async fn load_goal(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<StoredGoal, ApiError>
{
    let row = sqlx::query!(
        r#"
        SELECT mode AS "mode: GoalMode", pace_kg, target_kg, is_custom, custom_kcal, custom_prot, custom_fat, custom_carb
        FROM nutrition_goals
        WHERE user_id = $1
        "#,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    Ok(match row
    {
        Some(row) => StoredGoal {
            mode: row.mode,
            pace_kg: row.pace_kg.map(|value| value.normalize()),
            target_kg: row.target_kg.map(|value| value.normalize()),
            is_custom: row.is_custom,
            custom: item_per_100(row.custom_kcal, row.custom_prot, row.custom_fat, row.custom_carb),
        },
        None => StoredGoal {
            mode: GoalMode::Maintain,
            pace_kg: None,
            target_kg: None,
            is_custom: false,
            custom: None,
        },
    })
}

async fn load_body(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_date: NaiveDate,
    a_at: DateTime<Utc>,
) -> Result<BodyProfile, ApiError>
{
    let profile = sqlx::query!(
        r#"
        SELECT
            u.birth_date,
            u.sex AS "sex: Sex",
            u.activity AS "activity: ActivityLevel",
            COALESCE(
                (
                    SELECT v.value FROM body_values v JOIN body_entries e ON e.id = v.entry_id
                    WHERE e.user_id = u.id AND v.metric = 'weight' AND e.measured_ts < $2
                    ORDER BY e.measured_ts DESC LIMIT 1
                ),
                (
                    SELECT v.value FROM body_values v JOIN body_entries e ON e.id = v.entry_id
                    WHERE e.user_id = u.id AND v.metric = 'weight'
                    ORDER BY e.measured_ts LIMIT 1
                )
            ) AS "weight_kg?",
            (
                SELECT v.value FROM body_values v JOIN body_entries e ON e.id = v.entry_id
                WHERE e.user_id = u.id AND v.metric = 'height'
                ORDER BY e.measured_ts DESC LIMIT 1
            ) AS "height_cm?",
            (
                SELECT COUNT(*) FROM workout_sessions w
                WHERE w.user_id = u.id AND w.finished_ts IS NOT NULL AND w.started_ts < $2 AND w.started_ts >= $3
            ) AS "recent_workouts!"
        FROM users u
        WHERE u.id = $1
        "#,
        a_user_id,
        a_at,
        a_at - Duration::days(RECENT_WORKOUT_DAYS)
    )
    .fetch_one(&mut *a_conn)
    .await?;
    Ok(BodyProfile {
        sex: profile.sex,
        birth_date: profile.birth_date,
        on: a_date,
        weight_kg: profile.weight_kg,
        height_cm: profile.height_cm,
        activity: profile.activity,
        recent_workouts: profile.recent_workouts,
    })
}

fn norm_result(a_result: Result<NutritionNormDto, Vec<NormGap>>) -> (Option<NutritionNormDto>, Vec<NormGap>)
{
    match a_result
    {
        Ok(norm) => (Some(norm), Vec::new()),
        Err(gaps) => (None, gaps),
    }
}

pub async fn load_norm(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_date: NaiveDate,
    a_at: DateTime<Utc>,
) -> Result<(Option<NutritionNormDto>, Vec<NormGap>), ApiError>
{
    let body = load_body(a_conn, a_user_id, a_date, a_at).await?;
    let goal = load_goal(a_conn, a_user_id).await?;
    Ok(norm_result(daily_norm(&body, &goal.settings())))
}

fn goal_dto(a_goal: &StoredGoal, a_body: &BodyProfile) -> NutritionGoalDto
{
    let (norm, norm_gaps) = norm_result(daily_norm(a_body, &a_goal.settings()));
    NutritionGoalDto {
        mode: a_goal.mode,
        pace_kg: a_goal.pace_kg,
        target_kg: a_goal.target_kg,
        is_custom: a_goal.is_custom,
        custom: a_goal.custom,
        is_child: is_child(a_body.birth_date, a_body.on),
        norm,
        norm_gaps,
    }
}

fn clean_goal_request(a_req: SaveGoalRequest, a_is_child: bool) -> Result<StoredGoal, ApiError>
{
    let custom = a_req
        .custom
        .map(clean_custom)
        .transpose()
        .map_err(ApiError::Validation)?;
    if a_req.is_custom && custom.is_none()
    {
        return Err(ApiError::Validation("custom"));
    }
    let settings = clean_goal(
        GoalSettings {
            mode: a_req.mode,
            pace_kg: a_req.pace_kg,
            target_kg: a_req.target_kg,
            custom: custom.filter(|_| a_req.is_custom),
        },
        a_is_child,
    )
    .map_err(ApiError::Validation)?;
    Ok(StoredGoal {
        mode: settings.mode,
        pace_kg: settings.pace_kg,
        target_kg: settings.target_kg,
        is_custom: a_req.is_custom,
        custom,
    })
}

async fn today_body(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<BodyProfile, ApiError>
{
    let now = Utc::now();
    load_body(a_conn, a_user_id, now.date_naive(), now).await
}

pub async fn get_goal(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<PersonQuery>,
) -> Result<Json<NutritionGoalDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let person_id = acting_for(&mut conn, a_user.user_id, a_query.person_id).await?;
    let body = today_body(&mut conn, person_id).await?;
    let goal = load_goal(&mut conn, person_id).await?;
    Ok(Json(goal_dto(&goal, &body)))
}

pub async fn preview_goal(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveGoalRequest>,
) -> Result<Json<NutritionGoalDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let person_id = acting_for(&mut conn, a_user.user_id, a_req.person_id).await?;
    let body = today_body(&mut conn, person_id).await?;
    let goal = clean_goal_request(a_req, is_child(body.birth_date, body.on))?;
    Ok(Json(goal_dto(&goal, &body)))
}

pub async fn save_goal(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveGoalRequest>,
) -> Result<Json<NutritionGoalDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let person_id = acting_for(&mut tx, a_user.user_id, a_req.person_id).await?;
    let body = today_body(&mut tx, person_id).await?;
    let goal = clean_goal_request(a_req, is_child(body.birth_date, body.on))?;
    let custom = goal.custom;
    sqlx::query!(
        r#"
        INSERT INTO nutrition_goals (
            user_id, mode, pace_kg, target_kg, is_custom, custom_kcal, custom_prot, custom_fat, custom_carb
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (user_id) DO UPDATE
        SET mode = EXCLUDED.mode, pace_kg = EXCLUDED.pace_kg, target_kg = EXCLUDED.target_kg,
            is_custom = EXCLUDED.is_custom, custom_kcal = EXCLUDED.custom_kcal, custom_prot = EXCLUDED.custom_prot,
            custom_fat = EXCLUDED.custom_fat, custom_carb = EXCLUDED.custom_carb, updated_ts = NOW()
        "#,
        person_id,
        goal.mode as GoalMode,
        goal.pace_kg,
        goal.target_kg,
        goal.is_custom,
        custom.map(|value| value.kcal),
        custom.map(|value| value.prot),
        custom.map(|value| value.fat),
        custom.map(|value| value.carb)
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(goal_dto(&goal, &body)))
}

pub async fn person_norm(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<PersonNormQuery>,
) -> Result<Json<PersonNormDto>, ApiError>
{
    if a_query.tz_offset_min.abs() > MAX_TZ_OFFSET_MIN
    {
        return Err(ApiError::Validation("tz_offset_min"));
    }
    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_id).await?;
    let date = a_query.date;
    let day_end = date.and_hms_opt(0, 0, 0).ok_or(ApiError::Validation("date"))?.and_utc()
        - Duration::minutes(i64::from(a_query.tz_offset_min))
        + Duration::days(1);
    let body = load_body(&mut conn, a_id, date, day_end).await?;
    let goal = load_goal(&mut conn, a_id).await?;
    let (norm, norm_gaps) = norm_result(daily_norm(&body, &goal.settings()));
    let eaten = sqlx::query!(
        r#"
        SELECT COALESCE(SUM(kcal), 0) AS "kcal!", COALESCE(SUM(prot), 0) AS "prot!",
               COALESCE(SUM(fat), 0) AS "fat!", COALESCE(SUM(carb), 0) AS "carb!"
        FROM meal_entries
        WHERE user_id = $1 AND eaten_on = $2
        "#,
        a_id,
        date
    )
    .fetch_one(&mut *conn)
    .await?;
    Ok(Json(PersonNormDto {
        is_child: is_child(body.birth_date, date),
        norm,
        norm_gaps,
        eaten: MacrosDto {
            kcal: eaten.kcal.normalize(),
            prot: eaten.prot.normalize(),
            fat: eaten.fat.normalize(),
            carb: eaten.carb.normalize(),
        },
    }))
}

pub async fn recent_foods(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<PersonQuery>,
) -> Result<Json<Vec<RecentFoodDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let person_id = acting_for(&mut conn, a_user.user_id, a_query.person_id).await?;
    let rows = sqlx::query!(
        r#"
        SELECT
            r.source AS "source!: MealSource",
            r.item_id,
            r.dish_id,
            r.title AS "title!",
            r.grams,
            r.portions,
            r.is_ml AS "is_ml!",
            r.kcal_100,
            r.prot_100,
            r.fat_100,
            r.carb_100,
            r.created_ts AS "created_ts!"
        FROM (
            SELECT DISTINCT ON (me.source, COALESCE(me.dish_id, me.item_id))
                me.source, me.item_id, me.dish_id, me.title, me.grams, me.portions, me.is_ml,
                me.kcal_100, me.prot_100, me.fat_100, me.carb_100, me.created_ts
            FROM meal_entries me
            LEFT JOIN dishes d ON d.id = me.dish_id
            WHERE me.user_id = $1
              AND me.source <> 'quick'
              AND COALESCE(me.dish_id, me.item_id) IS NOT NULL
              AND (
                  me.dish_id IS NULL
                  OR d.owner_id = $1
                  OR (d.is_shared AND EXISTS (
                      SELECT 1
                      FROM family_mems mine
                      JOIN family_mems theirs ON theirs.family_id = mine.family_id
                      WHERE mine.user_id = $1 AND theirs.user_id = d.owner_id
                  ))
              )
            ORDER BY me.source, COALESCE(me.dish_id, me.item_id), me.created_ts DESC
        ) r
        ORDER BY r.created_ts DESC
        LIMIT $2
        "#,
        person_id,
        RECENT_LIMIT
    )
    .fetch_all(&mut *conn)
    .await?;

    Ok(Json(
        rows.into_iter()
            .map(|row| RecentFoodDto {
                source: row.source,
                item_id: row.item_id,
                dish_id: row.dish_id,
                title: row.title,
                grams: row.grams.map(|value| value.normalize()),
                portions: row.portions.map(|value| value.normalize()),
                is_ml: row.is_ml,
                per_100: item_per_100(row.kcal_100, row.prot_100, row.fat_100, row.carb_100),
                last_ts: row.created_ts,
            })
            .collect(),
    ))
}

pub async fn copy_meals(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CopyMealsRequest>,
) -> Result<Json<CopyMealsDto>, ApiError>
{
    let date = check_date(a_req.date, "date")?;
    let mut tx = a_state.db.begin().await?;
    let person_id = acting_for(&mut tx, a_user.user_id, a_req.person_id).await?;
    let start = meal_mark_start(&mut tx, person_id, a_req.status_mark_id).await?;
    require_near(date, start)?;
    let same_time = start - Duration::hours(COPY_BACK_HOURS);
    let source = sqlx::query!(
        r#"
        SELECT m.id, m.start_ts
        FROM status_marks m
        WHERE m.user_id = $1 AND m.status = 'meal' AND m.id <> $2 AND m.start_ts BETWEEN $3 AND $4
          AND EXISTS (SELECT 1 FROM meal_entries e WHERE e.status_mark_id = m.id)
        ORDER BY ABS(EXTRACT(EPOCH FROM (m.start_ts - $5))), m.start_ts
        LIMIT 1
        "#,
        person_id,
        a_req.status_mark_id,
        same_time - Duration::hours(COPY_WINDOW_HOURS),
        same_time + Duration::hours(COPY_WINDOW_HOURS),
        same_time
    )
    .fetch_optional(&mut *tx)
    .await?;
    let Some(source) = source
    else
    {
        return Ok(Json(CopyMealsDto {
            copied: 0,
            source_start_ts: None,
        }));
    };

    let pending = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM meal_entries WHERE user_id = $1 AND status_mark_id = $2"#,
        person_id,
        source.id
    )
    .fetch_one(&mut *tx)
    .await?;
    require_day_capacity(&mut tx, person_id, date, pending).await?;

    let copied = sqlx::query!(
        r#"
        INSERT INTO meal_entries (
            user_id, eaten_on, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
            kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb, status_mark_id, batch_id, created_ts
        )
        SELECT user_id, $3, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
               kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb, $4, batch_id,
               NOW() + (ROW_NUMBER() OVER (ORDER BY created_ts, id)) * INTERVAL '1 microsecond'
        FROM meal_entries
        WHERE user_id = $1 AND status_mark_id = $2
        RETURNING id, source AS "source: MealSource", item_id, batch_id, grams
        "#,
        person_id,
        source.id,
        date,
        a_req.status_mark_id
    )
    .fetch_all(&mut *tx)
    .await?;
    for entry in &copied
    {
        if entry.source != MealSource::Dish || entry.batch_id.is_some()
        {
            take_from_stock(
                &mut tx,
                a_user.user_id,
                entry.id,
                entry.item_id,
                entry.batch_id,
                entry.grams,
            )
            .await?;
        }
    }

    tx.commit().await?;
    Ok(Json(CopyMealsDto {
        copied: copied.len(),
        source_start_ts: Some(source.start_ts),
    }))
}
