use std::collections::{BTreeSet, HashMap};

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    ActivityLevel, CopyMealsDto, CopyMealsRequest, DishDto, DishIngredientDto, DishQuery, ItemKind, ItemUnit,
    MacrosDto, MealEntryDto, MealGroupDto, MealSlot, MealSource, NewMealEntryRequest, NutritionDayDto,
    NutritionDayQuery, QuickEntryRequest, RecentFoodDto, SaveDishRequest, Sex, UpdateMealEntryRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::user_handlers::age_on;
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text, contains_pattern};
use crate::services::nutrition::{
    amount, dish_math, for_grams, maintenance_norm, portion_grams, sum, BodyProfile, Ingredient,
};
use crate::state::AppState;

const MAX_DISHES_PER_USER: i64 = 300;
const MAX_INGREDIENTS: usize = 50;
const MAX_DISH_NAME_LEN: usize = 100;
const MAX_NOTE_LEN: usize = 500;
const MAX_TITLE_LEN: usize = 200;
const MAX_INGREDIENT_G: i64 = 20_000;
const MAX_COOKED_G: i64 = 100_000;
const COOKED_RATIO_LIMIT: i64 = 10;
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
    meal: MealSlot,
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
    created_ts: DateTime<Utc>,
}

struct Snapshot
{
    source: MealSource,
    item_id: Option<Uuid>,
    dish_id: Option<Uuid>,
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
            meal: a_row.meal,
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
            created_ts: a_row.created_ts,
        }
    }
}

fn item_per_100(
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

fn bounded(a_value: Decimal, a_max: i64, a_field: &'static str) -> Result<Decimal, ApiError>
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

async fn load_dish(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<DishDto, ApiError>
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

async fn require_food_items(a_conn: &mut PgConnection, a_item_ids: &[Uuid]) -> Result<(), ApiError>
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

    Ok(Snapshot {
        source: MealSource::Dish,
        item_id: None,
        dish_id: Some(a_dish_id),
        title: Some(dish.name),
        grams: Some(grams),
        portions,
        portion_g: portions.and(dish.portion_g),
        is_ml: false,
        per_100: Some(dish.per_100),
        total: for_grams(dish.per_100, grams),
    })
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

pub async fn require_meal_mark(a_conn: &mut PgConnection, a_user_id: Uuid, a_mark_id: Uuid) -> Result<(), ApiError>
{
    let is_meal = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM status_marks WHERE id = $1 AND user_id = $2 AND status = 'meal') AS "is_meal!""#,
        a_mark_id,
        a_user_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if !is_meal
    {
        return Err(ApiError::Validation("status_mark_id"));
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
        SELECT id, eaten_on, meal AS "meal: MealSlot", source AS "source: MealSource", item_id, dish_id, title,
               grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               status_mark_id, created_ts
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
    let snapshot = match (a_req.item_id, a_req.dish_id, a_req.quick.as_ref())
    {
        (Some(item_id), None, None) => item_snapshot(&mut tx, item_id, a_req.grams, a_req.portions).await?,
        (None, Some(dish_id), None) =>
        {
            dish_snapshot(&mut tx, a_user.user_id, dish_id, a_req.grams, a_req.portions).await?
        }
        (None, None, Some(quick)) if a_req.grams.is_none() && a_req.portions.is_none() => quick_snapshot(quick)?,
        _ => return Err(ApiError::Validation("source")),
    };
    require_day_capacity(&mut tx, a_user.user_id, date, 1).await?;
    if let Some(mark_id) = a_req.status_mark_id
    {
        require_meal_mark(&mut tx, a_user.user_id, mark_id).await?;
    }

    let per_100 = snapshot.per_100;
    let row = sqlx::query_as!(
        EntryRow,
        r#"
        INSERT INTO meal_entries (
            user_id, eaten_on, meal, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
            kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb, status_mark_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20)
        RETURNING id, eaten_on, meal AS "meal: MealSlot", source AS "source: MealSource", item_id, dish_id, title,
                  grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
                  status_mark_id, created_ts
        "#,
        a_user.user_id,
        date,
        a_req.meal as MealSlot,
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
        a_req.status_mark_id
    )
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(row.into())))
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
    let current = sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, eaten_on, meal AS "meal: MealSlot", source AS "source: MealSource", item_id, dish_id, title,
               grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               status_mark_id, created_ts
        FROM meal_entries
        WHERE id = $1 AND user_id = $2
        FOR UPDATE
        "#,
        a_id,
        a_user.user_id
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
    if date != current.eaten_on
    {
        require_day_capacity(&mut tx, a_user.user_id, date, 1).await?;
    }

    let row = sqlx::query_as!(
        EntryRow,
        r#"
        UPDATE meal_entries
        SET eaten_on = $2, meal = $3, title = $4, grams = $5, portions = $6, kcal = $7, prot = $8, fat = $9,
            carb = $10
        WHERE id = $1
        RETURNING id, eaten_on, meal AS "meal: MealSlot", source AS "source: MealSource", item_id, dish_id, title,
                  grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
                  status_mark_id, created_ts
        "#,
        a_id,
        date,
        a_req.meal as MealSlot,
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

    tx.commit().await?;
    Ok(Json(row.into()))
}

pub async fn delete_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM meal_entries WHERE id = $1 AND user_id = $2",
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

    let rows = sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, eaten_on, meal AS "meal: MealSlot", source AS "source: MealSource", item_id, dish_id, title,
               grams, portions, portion_g, is_ml, kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               status_mark_id, created_ts
        FROM meal_entries
        WHERE user_id = $1 AND eaten_on = $2
        ORDER BY created_ts, id
        "#,
        a_user.user_id,
        date
    )
    .fetch_all(&mut *conn)
    .await?;
    let entries: Vec<MealEntryDto> = rows.into_iter().map(MealEntryDto::from).collect();
    let meals: Vec<MealGroupDto> = MealSlot::ALL
        .into_iter()
        .map(|meal| {
            let entries: Vec<MealEntryDto> = entries.iter().filter(|entry| entry.meal == meal).cloned().collect();
            MealGroupDto {
                meal,
                total: sum(entries.iter().map(|entry| entry.total)),
                entries,
            }
        })
        .collect();
    let total = sum(meals.iter().map(|group| group.total));

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
            ) AS "height_cm?"
        FROM users u
        WHERE u.id = $1
        "#,
        a_user.user_id,
        day_end
    )
    .fetch_one(&mut *conn)
    .await?;
    let body = BodyProfile {
        sex: profile.sex,
        age: age_on(profile.birth_date, date),
        weight_kg: profile.weight_kg,
        height_cm: profile.height_cm,
        activity: profile.activity,
    };
    let (norm, norm_gaps) = match maintenance_norm(&body)
    {
        Ok(norm) => (Some(norm), Vec::new()),
        Err(gaps) => (None, gaps),
    };

    let workout_kcal = sqlx::query_scalar!(
        r#"
        SELECT COALESCE(SUM(kcal), 0)::numeric AS "kcal!"
        FROM workout_sessions
        WHERE user_id = $1 AND finished_ts IS NOT NULL AND started_ts >= $2 AND started_ts < $3
        "#,
        a_user.user_id,
        day_start,
        day_end
    )
    .fetch_one(&mut *conn)
    .await?;

    Ok(Json(NutritionDayDto {
        date,
        total,
        meals,
        norm,
        norm_gaps,
        workout_kcal: workout_kcal.round_dp(0).normalize(),
    }))
}

pub async fn recent_foods(
    State(a_state): State<AppState>,
    a_user: AuthUser,
) -> Result<Json<Vec<RecentFoodDto>>, ApiError>
{
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
        a_user.user_id,
        RECENT_LIMIT
    )
    .fetch_all(&a_state.db)
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
    let from = check_date(a_req.from, "from")?;
    let to = check_date(a_req.to, "to")?;
    if from == to
    {
        return Err(ApiError::Validation("to"));
    }
    let mut tx = a_state.db.begin().await?;
    let pending = sqlx::query_scalar!(
        r#"
        SELECT COUNT(*) AS "count!"
        FROM meal_entries
        WHERE user_id = $1 AND eaten_on = $2 AND ($3::meal_t IS NULL OR meal = $3)
        "#,
        a_user.user_id,
        from,
        a_req.meal as Option<MealSlot>
    )
    .fetch_one(&mut *tx)
    .await?;
    require_day_capacity(&mut tx, a_user.user_id, to, pending).await?;

    let copied = sqlx::query!(
        r#"
        INSERT INTO meal_entries (
            user_id, eaten_on, meal, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
            kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb, created_ts
        )
        SELECT user_id, $3, meal, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
               kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb,
               NOW() + (ROW_NUMBER() OVER (ORDER BY created_ts, id)) * INTERVAL '1 microsecond'
        FROM meal_entries
        WHERE user_id = $1 AND eaten_on = $2 AND ($4::meal_t IS NULL OR meal = $4)
        "#,
        a_user.user_id,
        from,
        to,
        a_req.meal as Option<MealSlot>
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(Json(CopyMealsDto {
        copied: usize::try_from(copied.rows_affected()).unwrap_or_default(),
    }))
}
