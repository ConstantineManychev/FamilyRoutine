use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ActivityLevel, ItemUnit, StatusMarkDto};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "meal_source_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum MealSource
{
    Item,
    Dish,
    Quick,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NormGap
{
    Weight,
    Height,
    Sex,
    Activity,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "goal_mode_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum GoalMode
{
    Lose,
    #[default]
    Maintain,
    Gain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NormKind
{
    Adult,
    Child,
    Custom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NormWarning
{
    DeficitCapped,
    FloorReached,
    SurplusCapped,
    SurplusRaised,
    TargetPassed,
    CustomBelowFloor,
    CustomMacrosMismatch,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MacrosDto
{
    pub kcal: Decimal,
    pub prot: Decimal,
    pub fat: Decimal,
    pub carb: Decimal,
}

#[derive(Debug, Clone, Serialize)]
pub struct DishIngredientDto
{
    pub item_id: Uuid,
    pub item_name: String,
    pub unit: ItemUnit,
    pub piece_g: Option<Decimal>,
    pub grams: Decimal,
    pub per_100: Option<MacrosDto>,
    pub total: MacrosDto,
}

#[derive(Debug, Clone, Serialize)]
pub struct DishDto
{
    pub id: Uuid,
    pub name: String,
    pub note: Option<String>,
    pub raw_g: Decimal,
    pub cooked_g: Decimal,
    pub is_cooked_set: bool,
    pub serving_g: Option<Decimal>,
    pub servings: Option<i32>,
    pub portion_g: Option<Decimal>,
    pub per_100: MacrosDto,
    pub total: MacrosDto,
    pub ingredient_count: usize,
    pub missing_count: usize,
    pub is_shared: bool,
    pub is_editable: bool,
    pub owner_name: Option<String>,
    pub updated_ts: DateTime<Utc>,
    pub ingredients: Vec<DishIngredientDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DishIngredientRequest
{
    pub item_id: Uuid,
    pub grams: Decimal,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveDishRequest
{
    pub name: String,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub cooked_g: Option<Decimal>,
    #[serde(default)]
    pub serving_g: Option<Decimal>,
    #[serde(default)]
    pub servings: Option<i32>,
    #[serde(default)]
    pub is_shared: bool,
    pub ingredients: Vec<DishIngredientRequest>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct DishQuery
{
    #[serde(default)]
    pub q: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MealEntryDto
{
    pub id: Uuid,
    pub date: NaiveDate,
    pub source: MealSource,
    pub item_id: Option<Uuid>,
    pub dish_id: Option<Uuid>,
    pub title: Option<String>,
    pub grams: Option<Decimal>,
    pub portions: Option<Decimal>,
    pub portion_g: Option<Decimal>,
    pub is_ml: bool,
    pub per_100: Option<MacrosDto>,
    pub total: MacrosDto,
    pub status_mark_id: Option<Uuid>,
    pub batch_id: Option<Uuid>,
    pub stock_short: Option<Decimal>,
    pub is_pack_needed: bool,
    pub created_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DayMealDto
{
    pub mark: StatusMarkDto,
    pub total: MacrosDto,
    pub entries: Vec<MealEntryDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NutritionNormDto
{
    pub target: MacrosDto,
    pub kind: NormKind,
    pub mode: GoalMode,
    pub age: i32,
    pub maintenance_kcal: Option<Decimal>,
    pub bmr: Option<Decimal>,
    pub floor_kcal: Option<Decimal>,
    pub delta_kcal: Decimal,
    pub pace_kg: Option<Decimal>,
    pub effective_pace_kg: Option<Decimal>,
    pub target_kg: Option<Decimal>,
    pub weeks_to_target: Option<i32>,
    pub activity: Option<ActivityLevel>,
    pub weight_kg: Option<Decimal>,
    pub recent_workouts: i64,
    pub is_training_boost: bool,
    pub warnings: Vec<NormWarning>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NutritionDayDto
{
    pub date: NaiveDate,
    pub total: MacrosDto,
    pub meals: Vec<DayMealDto>,
    pub unlinked: Vec<MealEntryDto>,
    pub unlinked_total: MacrosDto,
    pub norm: Option<NutritionNormDto>,
    pub norm_gaps: Vec<NormGap>,
    pub workout_kcal: Decimal,
    pub person_id: Uuid,
    pub can_edit: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct NutritionGoalDto
{
    pub mode: GoalMode,
    pub pace_kg: Option<Decimal>,
    pub target_kg: Option<Decimal>,
    pub is_custom: bool,
    pub custom: Option<MacrosDto>,
    pub is_child: bool,
    pub norm: Option<NutritionNormDto>,
    pub norm_gaps: Vec<NormGap>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveGoalRequest
{
    #[serde(default)]
    pub person_id: Option<Uuid>,
    pub mode: GoalMode,
    #[serde(default)]
    pub pace_kg: Option<Decimal>,
    #[serde(default)]
    pub target_kg: Option<Decimal>,
    #[serde(default)]
    pub is_custom: bool,
    #[serde(default)]
    pub custom: Option<MacrosDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PersonNormDto
{
    pub is_child: bool,
    pub norm: Option<NutritionNormDto>,
    pub norm_gaps: Vec<NormGap>,
    pub eaten: MacrosDto,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PersonNormQuery
{
    pub date: NaiveDate,
    #[serde(default)]
    pub tz_offset_min: i32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NutritionDayQuery
{
    pub date: NaiveDate,
    #[serde(default)]
    pub tz_offset_min: i32,
    #[serde(default)]
    pub person_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct QuickEntryRequest
{
    #[serde(default)]
    pub title: Option<String>,
    pub kcal: Decimal,
    #[serde(default)]
    pub prot: Option<Decimal>,
    #[serde(default)]
    pub fat: Option<Decimal>,
    #[serde(default)]
    pub carb: Option<Decimal>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewMealEntryRequest
{
    #[serde(default)]
    pub person_id: Option<Uuid>,
    pub date: NaiveDate,
    pub status_mark_id: Uuid,
    #[serde(default)]
    pub item_id: Option<Uuid>,
    #[serde(default)]
    pub dish_id: Option<Uuid>,
    #[serde(default)]
    pub quick: Option<QuickEntryRequest>,
    #[serde(default)]
    pub grams: Option<Decimal>,
    #[serde(default)]
    pub portions: Option<Decimal>,
    #[serde(default)]
    pub batch_id: Option<Uuid>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateMealEntryRequest
{
    pub date: NaiveDate,
    #[serde(default)]
    pub status_mark_id: Option<Uuid>,
    #[serde(default)]
    pub grams: Option<Decimal>,
    #[serde(default)]
    pub portions: Option<Decimal>,
    #[serde(default)]
    pub quick: Option<QuickEntryRequest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CopyMealsRequest
{
    #[serde(default)]
    pub person_id: Option<Uuid>,
    pub status_mark_id: Uuid,
    pub date: NaiveDate,
}

#[derive(Debug, Clone, Serialize)]
pub struct CopyMealsDto
{
    pub copied: usize,
    pub source_start_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecentFoodDto
{
    pub source: MealSource,
    pub item_id: Option<Uuid>,
    pub dish_id: Option<Uuid>,
    pub title: String,
    pub grams: Option<Decimal>,
    pub portions: Option<Decimal>,
    pub is_ml: bool,
    pub per_100: Option<MacrosDto>,
    pub last_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CatEstimateDto
{
    pub cat_id: Uuid,
    pub per_100: MacrosDto,
    pub is_ml: bool,
    pub is_in_stock: bool,
}
