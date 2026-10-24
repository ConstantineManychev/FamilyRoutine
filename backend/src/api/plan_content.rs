use std::collections::HashMap;

use chrono::{DateTime, NaiveDate, Utc};
use chrono_tz::Tz;
use rust_decimal::Decimal;
use shared_schema::{
    MacrosDto, MealSource, PlanContentDto, PlanContentInput, PlanFoodDto, PlanStudyDto, PlanTaskDto, RoutineStatus,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::nutrition_handlers::{eat_plan_foods, food_snapshot, PlanMeal};
use crate::api::work_handlers::{archive_plan_tasks, create_plan_tasks};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text};
use crate::services::nutrition::sum;
use crate::services::planner::local_date;

const MAX_FOODS: usize = 50;
const MAX_TASKS: usize = 50;
const MAX_STUDIES: usize = 30;
const MAX_TASK_TITLE_LEN: usize = 200;
const MAX_STUDY_NOTE_LEN: usize = 2000;

struct FoodRow
{
    id: Uuid,
    event_id: Uuid,
    source: MealSource,
    item_id: Option<Uuid>,
    dish_id: Option<Uuid>,
    title: Option<String>,
    grams: Option<Decimal>,
    portions: Option<Decimal>,
    portion_g: Option<Decimal>,
    is_ml: bool,
    kcal: Decimal,
    prot: Decimal,
    fat: Decimal,
    carb: Decimal,
}

pub async fn content_scope(
    a_conn: &mut PgConnection,
    a_event_id: Uuid,
    a_occ_date: NaiveDate,
) -> Result<Option<NaiveDate>, ApiError>
{
    let is_custom = sqlx::query_scalar!(
        "SELECT is_custom FROM plan_instances WHERE event_id = $1 AND occ_date = $2",
        a_event_id,
        a_occ_date
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .unwrap_or(false);
    Ok(is_custom.then_some(a_occ_date))
}

pub async fn save_content(
    a_conn: &mut PgConnection,
    a_actor_id: Uuid,
    a_owner_id: Uuid,
    a_event_id: Uuid,
    a_scope: Option<NaiveDate>,
    a_category: Option<RoutineStatus>,
    a_input: &PlanContentInput,
) -> Result<(), ApiError>
{
    if (!a_input.foods.is_empty() && a_category != Some(RoutineStatus::Meal)) || a_input.foods.len() > MAX_FOODS
    {
        return Err(ApiError::Validation("foods"));
    }
    if (!a_input.tasks.is_empty() && a_category != Some(RoutineStatus::Work)) || a_input.tasks.len() > MAX_TASKS
    {
        return Err(ApiError::Validation("tasks"));
    }
    if (!a_input.studies.is_empty() && a_category != Some(RoutineStatus::School)) || a_input.studies.len() > MAX_STUDIES
    {
        return Err(ApiError::Validation("studies"));
    }
    clear_content(a_conn, a_event_id, a_scope).await?;

    for (position, food) in a_input.foods.iter().enumerate()
    {
        let snapshot = food_snapshot(a_conn, a_actor_id, food).await?;
        let per_100 = snapshot.per_100;
        sqlx::query!(
            r#"
            INSERT INTO plan_foods (
                event_id, occ_date, position, source, item_id, dish_id, title, grams, portions, portion_g, is_ml,
                kcal_100, prot_100, fat_100, carb_100, kcal, prot, fat, carb
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)
            "#,
            a_event_id,
            a_scope,
            position as i32,
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
            snapshot.total.carb
        )
        .execute(&mut *a_conn)
        .await?;
    }

    for (position, task) in a_input.tasks.iter().enumerate()
    {
        let title = clean_text(&task.title, 1, MAX_TASK_TITLE_LEN, "tasks")?;
        sqlx::query!(
            "INSERT INTO plan_tasks (event_id, occ_date, position, title) VALUES ($1, $2, $3, $4)",
            a_event_id,
            a_scope,
            position as i32,
            title
        )
        .execute(&mut *a_conn)
        .await?;
    }

    for (position, study) in a_input.studies.iter().enumerate()
    {
        let is_own = sqlx::query_scalar!(
            r#"SELECT EXISTS (SELECT 1 FROM study_topics WHERE id = $1 AND user_id = $2) AS "is_own!""#,
            study.topic_id,
            a_owner_id
        )
        .fetch_one(&mut *a_conn)
        .await?;
        if !is_own
        {
            return Err(ApiError::Validation("topic_id"));
        }
        let note = clean_optional_text(study.note.as_deref(), MAX_STUDY_NOTE_LEN, "studies")?;
        sqlx::query!(
            "INSERT INTO plan_studies (event_id, occ_date, position, topic_id, note) VALUES ($1, $2, $3, $4, $5)",
            a_event_id,
            a_scope,
            position as i32,
            study.topic_id,
            note
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
}

pub async fn clear_content(
    a_conn: &mut PgConnection,
    a_event_id: Uuid,
    a_scope: Option<NaiveDate>,
) -> Result<(), ApiError>
{
    sqlx::query!(
        "DELETE FROM plan_foods WHERE event_id = $1 AND occ_date IS NOT DISTINCT FROM $2",
        a_event_id,
        a_scope
    )
    .execute(&mut *a_conn)
    .await?;
    sqlx::query!(
        "DELETE FROM plan_tasks WHERE event_id = $1 AND occ_date IS NOT DISTINCT FROM $2",
        a_event_id,
        a_scope
    )
    .execute(&mut *a_conn)
    .await?;
    sqlx::query!(
        "DELETE FROM plan_studies WHERE event_id = $1 AND occ_date IS NOT DISTINCT FROM $2",
        a_event_id,
        a_scope
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

pub async fn drop_foreign_content(
    a_conn: &mut PgConnection,
    a_event_id: Uuid,
    a_category: Option<RoutineStatus>,
) -> Result<(), ApiError>
{
    if a_category != Some(RoutineStatus::Meal)
    {
        sqlx::query!("DELETE FROM plan_foods WHERE event_id = $1", a_event_id)
            .execute(&mut *a_conn)
            .await?;
    }
    if a_category != Some(RoutineStatus::Work)
    {
        sqlx::query!("DELETE FROM plan_tasks WHERE event_id = $1", a_event_id)
            .execute(&mut *a_conn)
            .await?;
    }
    if a_category != Some(RoutineStatus::School)
    {
        sqlx::query!("DELETE FROM plan_studies WHERE event_id = $1", a_event_id)
            .execute(&mut *a_conn)
            .await?;
    }
    Ok(())
}

pub async fn load_contents(
    a_conn: &mut PgConnection,
    a_event_ids: &[Uuid],
    a_scope: Option<NaiveDate>,
) -> Result<HashMap<Uuid, PlanContentDto>, ApiError>
{
    let mut contents: HashMap<Uuid, PlanContentDto> = HashMap::new();
    let foods = sqlx::query_as!(
        FoodRow,
        r#"
        SELECT id, event_id, source AS "source: MealSource", item_id, dish_id, title, grams, portions, portion_g, is_ml,
               kcal, prot, fat, carb
        FROM plan_foods
        WHERE event_id = ANY($1) AND occ_date IS NOT DISTINCT FROM $2
        ORDER BY event_id, position
        "#,
        a_event_ids,
        a_scope
    )
    .fetch_all(&mut *a_conn)
    .await?;
    for food in foods
    {
        contents.entry(food.event_id).or_default().foods.push(PlanFoodDto {
            id: food.id,
            source: food.source,
            item_id: food.item_id,
            dish_id: food.dish_id,
            title: food.title,
            grams: food.grams.map(|value| value.normalize()),
            portions: food.portions.map(|value| value.normalize()),
            portion_g: food.portion_g.map(|value| value.normalize()),
            is_ml: food.is_ml,
            total: MacrosDto {
                kcal: food.kcal.normalize(),
                prot: food.prot.normalize(),
                fat: food.fat.normalize(),
                carb: food.carb.normalize(),
            },
        });
    }

    for task in sqlx::query!(
        r#"
        SELECT id, event_id, title
        FROM plan_tasks
        WHERE event_id = ANY($1) AND occ_date IS NOT DISTINCT FROM $2
        ORDER BY event_id, position
        "#,
        a_event_ids,
        a_scope
    )
    .fetch_all(&mut *a_conn)
    .await?
    {
        contents.entry(task.event_id).or_default().tasks.push(PlanTaskDto {
            id: task.id,
            title: task.title,
        });
    }

    for study in sqlx::query!(
        r#"
        SELECT s.id, s.event_id, s.topic_id, t.title AS topic_title, s.note
        FROM plan_studies s
        JOIN study_topics t ON t.id = s.topic_id
        WHERE s.event_id = ANY($1) AND s.occ_date IS NOT DISTINCT FROM $2
        ORDER BY s.event_id, s.position
        "#,
        a_event_ids,
        a_scope
    )
    .fetch_all(&mut *a_conn)
    .await?
    {
        contents.entry(study.event_id).or_default().studies.push(PlanStudyDto {
            id: study.id,
            topic_id: study.topic_id,
            topic_title: study.topic_title,
            note: study.note,
        });
    }

    for content in contents.values_mut()
    {
        content.total = sum(content.foods.iter().map(|food| food.total));
    }
    Ok(contents)
}

pub async fn load_content(
    a_conn: &mut PgConnection,
    a_event_id: Uuid,
    a_scope: Option<NaiveDate>,
) -> Result<PlanContentDto, ApiError>
{
    Ok(load_contents(a_conn, &[a_event_id], a_scope)
        .await?
        .remove(&a_event_id)
        .unwrap_or_default())
}

pub struct ApplyTarget
{
    pub event_id: Uuid,
    pub occ_date: NaiveDate,
    pub category: Option<RoutineStatus>,
    pub zone: Tz,
}

pub async fn apply_content(
    a_conn: &mut PgConnection,
    a_actor_id: Uuid,
    a_owner_id: Uuid,
    a_target: &ApplyTarget,
    a_mark_id: Uuid,
    a_start: DateTime<Utc>,
) -> Result<(), ApiError>
{
    let scope = content_scope(a_conn, a_target.event_id, a_target.occ_date).await?;
    let day = local_date(a_target.zone, a_start);
    match a_target.category
    {
        Some(RoutineStatus::Meal) =>
        {
            let meal = PlanMeal {
                event_id: a_target.event_id,
                scope,
                occ_date: a_target.occ_date,
                eaten_on: day,
                mark_id: a_mark_id,
            };
            eat_plan_foods(a_conn, a_actor_id, a_owner_id, &meal).await
        }
        Some(RoutineStatus::Work) =>
        {
            create_plan_tasks(a_conn, a_owner_id, a_target.event_id, scope, a_target.occ_date, day).await
        }
        Some(RoutineStatus::School) =>
        {
            sqlx::query!(
                r#"
                INSERT INTO study_notes (topic_id, user_id, body, note_ts, plan_event_id, plan_occ_date)
                SELECT topic_id, $3, note, $4, event_id, $5
                FROM plan_studies
                WHERE event_id = $1 AND occ_date IS NOT DISTINCT FROM $2 AND note IS NOT NULL
                ORDER BY position
                "#,
                a_target.event_id,
                scope,
                a_owner_id,
                a_start,
                a_target.occ_date
            )
            .execute(&mut *a_conn)
            .await?;
            Ok(())
        }
        _ => Ok(()),
    }
}

pub async fn revert_content(a_conn: &mut PgConnection, a_event_id: Uuid, a_occ_date: NaiveDate)
    -> Result<(), ApiError>
{
    sqlx::query!(
        "DELETE FROM meal_entries WHERE plan_event_id = $1 AND plan_occ_date = $2",
        a_event_id,
        a_occ_date
    )
    .execute(&mut *a_conn)
    .await?;
    archive_plan_tasks(a_conn, a_event_id, a_occ_date).await?;
    sqlx::query!(
        "DELETE FROM study_notes WHERE plan_event_id = $1 AND plan_occ_date = $2",
        a_event_id,
        a_occ_date
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

pub async fn shift_content(
    a_conn: &mut PgConnection,
    a_target: &ApplyTarget,
    a_old_start: DateTime<Utc>,
    a_new_start: DateTime<Utc>,
) -> Result<(), ApiError>
{
    let day = local_date(a_target.zone, a_new_start);
    sqlx::query!(
        "UPDATE meal_entries SET eaten_on = $3 WHERE plan_event_id = $1 AND plan_occ_date = $2",
        a_target.event_id,
        a_target.occ_date,
        day
    )
    .execute(&mut *a_conn)
    .await?;
    sqlx::query!(
        r#"
        UPDATE work_tasks SET start_on = $3, updated_ts = NOW()
        WHERE plan_event_id = $1 AND plan_occ_date = $2 AND done_on IS NULL AND deleted_ts IS NULL
        "#,
        a_target.event_id,
        a_target.occ_date,
        day
    )
    .execute(&mut *a_conn)
    .await?;
    sqlx::query!(
        r#"
        UPDATE study_notes SET note_ts = note_ts + ($3::timestamptz - $4::timestamptz), updated_ts = NOW()
        WHERE plan_event_id = $1 AND plan_occ_date = $2
        "#,
        a_target.event_id,
        a_target.occ_date,
        a_new_start,
        a_old_start
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}
