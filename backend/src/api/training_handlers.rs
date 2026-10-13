use std::collections::{HashMap, HashSet};

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use shared_schema::{
    ExType, FinishSessionRequest, PersonTrainingDto, PlanQuery, PlannedWorkoutDto, ProgramDayDto, ProgramDto,
    ProgramExerciseDto, ProgramListItemDto, RoutineStatus, SaveProgramRequest, SaveSessionExercise, SaveSessionRequest,
    ScheduleMode, SessionDto, SessionExerciseDto, SessionSetDto, SessionSummaryDto, SessionsQuery, SetTodayRequest,
    StartSessionRequest, TrainingPlanDto,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::routine_handlers::place_mark;
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_name, clean_optional_text};
use crate::security::profile_access::profile_access;
use crate::services::training_schedule::{plan, Planned, Reference, ScheduleDay};
use crate::services::workout_calc::{average_met, session_kcal, ExerciseLoad};
use crate::state::AppState;

const MAX_PROGRAMS: i64 = 20;
const MAX_DAYS: usize = 14;
const MAX_DAY_EXERCISES: usize = 30;
const MAX_SESSION_EXERCISES: usize = 40;
const MAX_SETS: usize = 30;
const MAX_REST_DAYS: i32 = 14;
const MAX_NOTE_LEN: usize = 200;
const MAX_SESSION_NOTE_LEN: usize = 500;
const DEFAULT_HORIZON_DAYS: i64 = 14;
const MAX_HORIZON_DAYS: i64 = 60;
const MAX_TZ_OFFSET_MIN: i32 = 14 * 60;
const MAX_BACKDATE_DAYS: i64 = 7;
const CLOCK_SKEW_MINUTES: i64 = 5;
const MAX_SESSION_HOURS: i64 = 12;
const DEFAULT_SESSIONS_LIMIT: i64 = 20;
const MAX_SESSIONS_LIMIT: i64 = 200;
const WEIGHT_SCALE: u32 = 2;

struct ProgramRow
{
    id: Uuid,
    name: String,
    schedule_mode: ScheduleMode,
    is_active: bool,
    created_ts: DateTime<Utc>,
}

struct DayRow
{
    id: Uuid,
    name: String,
    rest_days_after: i32,
    weekday_mask: i32,
}

struct ProgramExRow
{
    day_id: Uuid,
    ex_id: Uuid,
    sets: i32,
    reps_min: Option<i32>,
    reps_max: Option<i32>,
    duration_sec: Option<i32>,
    weight_kg: Option<Decimal>,
    rest_sec: Option<i32>,
    weight_step: Option<Decimal>,
    note: Option<String>,
}

struct SessionRow
{
    id: Uuid,
    program_id: Option<Uuid>,
    program_name: Option<String>,
    day_id: Option<Uuid>,
    day_name: Option<String>,
    started_ts: DateTime<Utc>,
    finished_ts: Option<DateTime<Utc>>,
    intensity: Option<i32>,
    kcal: Option<Decimal>,
    note: Option<String>,
    status_mark_id: Option<Uuid>,
}

struct SessionExRow
{
    id: Uuid,
    ex_id: Uuid,
    ex_code: Option<String>,
    ex_name: String,
    ex_type: ExType,
    reps_min: Option<i32>,
    reps_max: Option<i32>,
    duration_sec: Option<i32>,
    target_weight: Option<Decimal>,
    rest_sec: Option<i32>,
}

struct SetRow
{
    session_exercise_id: Uuid,
    reps: Option<i32>,
    weight_kg: Option<Decimal>,
    duration_sec: Option<i32>,
    is_done: bool,
}

struct PreviousRow
{
    ex_id: Uuid,
    session_exercise_id: Uuid,
    started_ts: DateTime<Utc>,
}

pub async fn list_programs(
    State(a_state): State<AppState>,
    a_user: AuthUser,
) -> Result<Json<Vec<ProgramListItemDto>>, ApiError>
{
    let programs = sqlx::query_as!(
        ProgramListItemDto,
        r#"
        SELECT p.id, p.name, p.schedule_mode AS "schedule_mode: ScheduleMode", p.is_active,
               (SELECT COUNT(*) FROM program_days d WHERE d.program_id = p.id) AS "day_count!"
        FROM training_programs p
        WHERE p.user_id = $1
        ORDER BY p.is_active DESC, p.name
        "#,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(programs))
}

pub async fn get_program(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<ProgramDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_program(&mut conn, a_user.user_id, a_id).await.map(Json)
}

pub async fn create_program(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveProgramRequest>,
) -> Result<(StatusCode, Json<ProgramDto>), ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let program = clean_program(&mut tx, a_user.user_id, a_req).await?;

    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM training_programs WHERE user_id = $1"#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_PROGRAMS
    {
        return Err(ApiError::Conflict("TOO_MANY_PROGRAMS"));
    }

    let program_id = sqlx::query_scalar!(
        r#"
        INSERT INTO training_programs (user_id, name, schedule_mode, is_active)
        VALUES ($1, $2, $3, NOT EXISTS (SELECT 1 FROM training_programs WHERE user_id = $1 AND is_active))
        RETURNING id
        "#,
        a_user.user_id,
        program.name,
        program.schedule_mode as ScheduleMode
    )
    .fetch_one(&mut *tx)
    .await?;
    save_days(&mut tx, program_id, &program.days).await?;

    let dto = load_program(&mut tx, a_user.user_id, program_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(dto)))
}

pub async fn update_program(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveProgramRequest>,
) -> Result<Json<ProgramDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let program = clean_program(&mut tx, a_user.user_id, a_req).await?;

    let updated = sqlx::query!(
        r#"
        UPDATE training_programs SET name = $3, schedule_mode = $4, updated_ts = NOW()
        WHERE id = $1 AND user_id = $2
        "#,
        a_id,
        a_user.user_id,
        program.name,
        program.schedule_mode as ScheduleMode
    )
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    save_days(&mut tx, a_id, &program.days).await?;

    let dto = load_program(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(dto))
}

pub async fn delete_program(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM training_programs WHERE id = $1 AND user_id = $2",
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

pub async fn activate_program(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let exists = sqlx::query_scalar!(
        r#"SELECT EXISTS (SELECT 1 FROM training_programs WHERE id = $1 AND user_id = $2) AS "exists!""#,
        a_id,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if !exists
    {
        return Err(ApiError::NotFound);
    }

    sqlx::query!(
        "UPDATE training_programs SET is_active = FALSE WHERE user_id = $1 AND is_active AND id <> $2",
        a_user.user_id,
        a_id
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!("UPDATE training_programs SET is_active = TRUE WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn set_today(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SetTodayRequest>,
) -> Result<StatusCode, ApiError>
{
    let today = Utc::now().date_naive();
    if (a_req.date - today).num_days().abs() > 1
    {
        return Err(ApiError::Validation("date"));
    }

    let updated = sqlx::query!(
        r#"
        UPDATE training_programs p
        SET anchor_day_id = $2, anchor_date = $3, anchor_ts = NOW()
        WHERE p.user_id = $1 AND p.is_active
          AND EXISTS (SELECT 1 FROM program_days d WHERE d.id = $2 AND d.program_id = p.id)
        "#,
        a_user.user_id,
        a_req.day_id,
        a_req.date
    )
    .execute(&a_state.db)
    .await?;
    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

pub async fn get_plan(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<PlanQuery>,
) -> Result<Json<TrainingPlanDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    build_plan(&mut conn, a_user.user_id, &a_query).await.map(Json)
}

pub async fn person_training(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_person_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<PlanQuery>,
) -> Result<Json<PersonTrainingDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_person_id)
        .await?
        .require_training()?;

    let plan = build_plan(&mut conn, a_person_id, &a_query).await?;
    let program = match plan.program.as_ref()
    {
        Some(program) => Some(load_program(&mut conn, a_person_id, program.id).await?),
        None => None,
    };
    let sessions = load_summaries(&mut conn, a_person_id, DEFAULT_SESSIONS_LIMIT, false).await?;

    Ok(Json(PersonTrainingDto {
        plan,
        program,
        sessions,
    }))
}

pub async fn person_session(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_person_id, a_session_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<Json<SessionDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_person_id)
        .await?
        .require_training()?;
    load_session(&mut conn, a_person_id, a_session_id).await.map(Json)
}

async fn build_plan(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_query: &PlanQuery,
) -> Result<TrainingPlanDto, ApiError>
{
    if a_query.tz_offset_min.abs() > MAX_TZ_OFFSET_MIN
    {
        return Err(ApiError::Validation("tz_offset_min"));
    }
    let offset = Duration::minutes(i64::from(a_query.tz_offset_min));
    let horizon = a_query.days.unwrap_or(DEFAULT_HORIZON_DAYS).clamp(1, MAX_HORIZON_DAYS);
    let today = (Utc::now() + offset).date_naive();

    let program = sqlx::query!(
        r#"
        SELECT p.id, p.name, p.schedule_mode AS "schedule_mode: ScheduleMode", p.anchor_day_id, p.anchor_date, p.anchor_ts,
               (SELECT COUNT(*) FROM program_days d WHERE d.program_id = p.id) AS "day_count!"
        FROM training_programs p
        WHERE p.user_id = $1 AND p.is_active
        "#,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;

    let mut upcoming = Vec::new();
    let mut program_item = None;
    if let Some(program) = program
    {
        let days = load_days(a_conn, program.id).await?;
        let last_done = sqlx::query!(
            r#"
            SELECT day_id AS "day_id!", started_ts
            FROM workout_sessions
            WHERE user_id = $1 AND program_id = $2 AND day_id IS NOT NULL AND finished_ts IS NOT NULL
            ORDER BY started_ts DESC
            LIMIT 1
            "#,
            a_user_id,
            program.id
        )
        .fetch_optional(&mut *a_conn)
        .await?;

        let index_of = |a_day_id: Uuid| days.iter().position(|day| day.id == a_day_id);
        let done = last_done.and_then(|row| {
            index_of(row.day_id).map(|day_index| {
                (
                    row.started_ts,
                    Reference::Done {
                        day_index,
                        date: (row.started_ts + offset).date_naive(),
                    },
                )
            })
        });
        let chosen = match (program.anchor_day_id, program.anchor_date, program.anchor_ts)
        {
            (Some(day_id), Some(date), Some(set_ts)) =>
            {
                index_of(day_id).map(|day_index| (set_ts, Reference::Chosen { day_index, date }))
            }
            _ => None,
        };
        let reference = match (done, chosen)
        {
            (Some((done_ts, done)), Some((chosen_ts, chosen))) => Some(if chosen_ts > done_ts { chosen } else { done }),
            (done, chosen) => done.or(chosen).map(|(_, reference)| reference),
        };

        let schedule: Vec<ScheduleDay> = days
            .iter()
            .map(|day| ScheduleDay {
                rest_days_after: day.rest_days_after,
                weekday_mask: day.weekday_mask,
            })
            .collect();
        upcoming = plan(program.schedule_mode, &schedule, reference, today, horizon)
            .into_iter()
            .map(|item: Planned| PlannedWorkoutDto {
                day_id: days[item.day_index].id,
                day_name: days[item.day_index].name.clone(),
                date: item.date,
                is_overdue: item.is_overdue,
            })
            .collect();

        program_item = Some(ProgramListItemDto {
            id: program.id,
            name: program.name,
            schedule_mode: program.schedule_mode,
            is_active: true,
            day_count: program.day_count,
        });
    }

    let active_session_id = sqlx::query_scalar!(
        "SELECT id FROM workout_sessions WHERE user_id = $1 AND finished_ts IS NULL",
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    let last_session = load_summaries(a_conn, a_user_id, 1, true).await?.into_iter().next();

    Ok(TrainingPlanDto {
        program: program_item,
        upcoming,
        active_session_id,
        last_session,
    })
}

pub async fn list_sessions(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<SessionsQuery>,
) -> Result<Json<Vec<SessionSummaryDto>>, ApiError>
{
    let limit = a_query
        .limit
        .unwrap_or(DEFAULT_SESSIONS_LIMIT)
        .clamp(1, MAX_SESSIONS_LIMIT);
    let mut conn = a_state.db.acquire().await?;
    load_summaries(&mut conn, a_user.user_id, limit, false).await.map(Json)
}

pub async fn start_session(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<StartSessionRequest>,
) -> Result<(StatusCode, Json<SessionDto>), ApiError>
{
    let now = Utc::now();
    let started_ts = a_req.started_ts.unwrap_or(now);
    if started_ts < now - Duration::days(MAX_BACKDATE_DAYS) || started_ts > now + Duration::minutes(CLOCK_SKEW_MINUTES)
    {
        return Err(ApiError::Validation("started_ts"));
    }

    let mut tx = a_state.db.begin().await?;
    let open = sqlx::query_scalar!(
        r#"SELECT EXISTS (SELECT 1 FROM workout_sessions WHERE user_id = $1 AND finished_ts IS NULL) AS "exists!""#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if open
    {
        return Err(ApiError::Conflict("SESSION_ACTIVE"));
    }

    let day = match a_req.day_id
    {
        Some(day_id) => Some(
            sqlx::query!(
                r#"
                SELECT d.id, d.name, p.id AS program_id, p.name AS program_name
                FROM program_days d JOIN training_programs p ON p.id = d.program_id
                WHERE d.id = $1 AND p.user_id = $2
                "#,
                day_id,
                a_user.user_id
            )
            .fetch_optional(&mut *tx)
            .await?
            .ok_or(ApiError::NotFound)?,
        ),
        None => None,
    };

    let mark_note = day.as_ref().map(|day| day.name.clone());
    let mark = place_mark(&mut tx, a_user.user_id, RoutineStatus::Gym, mark_note, started_ts, None).await?;
    let session_id = sqlx::query_scalar!(
        r#"
        INSERT INTO workout_sessions (user_id, program_id, day_id, program_name, day_name, started_ts, status_mark_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id
        "#,
        a_user.user_id,
        day.as_ref().map(|day| day.program_id),
        day.as_ref().map(|day| day.id),
        day.as_ref().map(|day| day.program_name.clone()),
        day.as_ref().map(|day| day.name.clone()),
        started_ts,
        mark.id
    )
    .fetch_one(&mut *tx)
    .await?;

    if let Some(day) = &day
    {
        prefill_session(&mut tx, a_user.user_id, session_id, day.id, started_ts).await?;
    }

    let dto = load_session(&mut tx, a_user.user_id, session_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(dto)))
}

pub async fn get_session(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<SessionDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_session(&mut conn, a_user.user_id, a_id).await.map(Json)
}

pub async fn save_session(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveSessionRequest>,
) -> Result<Json<SessionDto>, ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_SESSION_NOTE_LEN, "note")?;
    let exercises = clean_session_exercises(a_req.exercises)?;

    let mut tx = a_state.db.begin().await?;
    let session = load_session_row(&mut tx, a_user.user_id, a_id).await?;
    let ex_ids: Vec<Uuid> = exercises.iter().map(|exercise| exercise.ex_id).collect();
    visible_exercises(&mut tx, a_user.user_id, &ex_ids).await?;

    sqlx::query!("UPDATE workout_sessions SET note = $2 WHERE id = $1", a_id, note)
        .execute(&mut *tx)
        .await?;
    sqlx::query!("DELETE FROM session_exercises WHERE session_id = $1", a_id)
        .execute(&mut *tx)
        .await?;
    for (position, exercise) in exercises.iter().enumerate()
    {
        insert_session_exercise(&mut tx, a_id, position as i32, exercise).await?;
    }

    if let (Some(finished_ts), Some(intensity)) = (session.finished_ts, session.intensity)
    {
        update_kcal(
            &mut tx,
            a_user.user_id,
            a_id,
            session.started_ts,
            finished_ts,
            intensity,
        )
        .await?;
    }

    let dto = load_session(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(dto))
}

pub async fn finish_session(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<FinishSessionRequest>,
) -> Result<Json<SessionDto>, ApiError>
{
    if !(1..=10).contains(&a_req.intensity)
    {
        return Err(ApiError::Validation("intensity"));
    }

    let now = Utc::now();
    let mut tx = a_state.db.begin().await?;
    let session = load_session_row(&mut tx, a_user.user_id, a_id).await?;
    if session.finished_ts.is_some()
    {
        return Err(ApiError::Conflict("SESSION_FINISHED"));
    }

    let finished_ts = a_req.finished_ts.unwrap_or(now).min(now);
    if finished_ts <= session.started_ts || finished_ts > session.started_ts + Duration::hours(MAX_SESSION_HOURS)
    {
        return Err(ApiError::Validation("finished_ts"));
    }

    sqlx::query!(
        "UPDATE workout_sessions SET finished_ts = $2, intensity = $3 WHERE id = $1",
        a_id,
        finished_ts,
        a_req.intensity
    )
    .execute(&mut *tx)
    .await?;
    update_kcal(
        &mut tx,
        a_user.user_id,
        a_id,
        session.started_ts,
        finished_ts,
        a_req.intensity,
    )
    .await?;

    if let Some(mark_id) = session.status_mark_id
    {
        sqlx::query!(
            "UPDATE status_marks SET end_ts = $3 WHERE id = $1 AND user_id = $2 AND end_ts IS NULL",
            mark_id,
            a_user.user_id,
            finished_ts
        )
        .execute(&mut *tx)
        .await?;
    }

    let dto = load_session(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(dto))
}

pub async fn delete_session(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let session = load_session_row(&mut tx, a_user.user_id, a_id).await?;
    sqlx::query!("DELETE FROM workout_sessions WHERE id = $1", a_id)
        .execute(&mut *tx)
        .await?;
    if let Some(mark_id) = session.status_mark_id
    {
        sqlx::query!(
            "DELETE FROM status_marks WHERE id = $1 AND user_id = $2",
            mark_id,
            a_user.user_id
        )
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn clean_program(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_req: SaveProgramRequest,
) -> Result<SaveProgramRequest, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    if a_req.days.is_empty() || a_req.days.len() > MAX_DAYS
    {
        return Err(ApiError::Validation("days"));
    }

    let mut used_weekdays = 0;
    let mut days = Vec::with_capacity(a_req.days.len());
    for day in a_req.days
    {
        let mask = weekday_mask(&day.weekdays)?;
        if a_req.schedule_mode == ScheduleMode::Weekdays && used_weekdays & mask != 0
        {
            return Err(ApiError::Validation("weekdays"));
        }
        used_weekdays |= mask;
        if !(0..=MAX_REST_DAYS).contains(&day.rest_days_after) || day.exercises.len() > MAX_DAY_EXERCISES
        {
            return Err(ApiError::Validation("days"));
        }
        let exercises = day
            .exercises
            .into_iter()
            .map(clean_program_exercise)
            .collect::<Result<Vec<_>, _>>()?;
        days.push(ProgramDayDto {
            id: day.id,
            name: clean_name(&day.name, "day_name")?,
            rest_days_after: day.rest_days_after,
            weekdays: weekdays_of(mask),
            exercises,
        });
    }
    if a_req.schedule_mode == ScheduleMode::Weekdays && used_weekdays == 0
    {
        return Err(ApiError::Validation("weekdays"));
    }

    let ex_ids: Vec<Uuid> = days
        .iter()
        .flat_map(|day| day.exercises.iter().map(|exercise| exercise.ex_id))
        .collect();
    visible_exercises(a_conn, a_user_id, &ex_ids).await?;

    Ok(SaveProgramRequest {
        name,
        schedule_mode: a_req.schedule_mode,
        days,
    })
}

fn clean_program_exercise(a_exercise: ProgramExerciseDto) -> Result<ProgramExerciseDto, ApiError>
{
    let is_valid = (1..=20).contains(&a_exercise.sets)
        && in_range(a_exercise.reps_min, 1, 200)
        && in_range(a_exercise.reps_max, 1, 200)
        && a_exercise
            .reps_min
            .zip(a_exercise.reps_max)
            .is_none_or(|(min, max)| min <= max)
        && in_range(a_exercise.duration_sec, 1, 7200)
        && in_range(a_exercise.rest_sec, 0, 900)
        && weight_in_range(a_exercise.weight_kg)
        && a_exercise
            .weight_step
            .is_none_or(|step| step > Decimal::ZERO && step <= Decimal::from(50));
    if !is_valid
    {
        return Err(ApiError::Validation("exercises"));
    }

    Ok(ProgramExerciseDto {
        note: clean_optional_text(a_exercise.note.as_deref(), MAX_NOTE_LEN, "note")?,
        weight_kg: a_exercise.weight_kg.map(|weight| weight.round_dp(WEIGHT_SCALE)),
        weight_step: a_exercise.weight_step.map(|step| step.round_dp(WEIGHT_SCALE)),
        ..a_exercise
    })
}

fn clean_session_exercises(a_exercises: Vec<SaveSessionExercise>) -> Result<Vec<SaveSessionExercise>, ApiError>
{
    if a_exercises.len() > MAX_SESSION_EXERCISES
    {
        return Err(ApiError::Validation("exercises"));
    }

    a_exercises
        .into_iter()
        .map(|exercise| {
            let is_valid = exercise.sets.len() <= MAX_SETS
                && weight_in_range(exercise.target_weight)
                && exercise.sets.iter().all(|set| {
                    in_range(set.reps, 0, 1000)
                        && weight_in_range(set.weight_kg)
                        && in_range(set.duration_sec, 0, 36_000)
                });
            if !is_valid
            {
                return Err(ApiError::Validation("exercises"));
            }
            Ok(SaveSessionExercise {
                sets: exercise
                    .sets
                    .into_iter()
                    .map(|set| SessionSetDto {
                        weight_kg: set.weight_kg.map(|weight| weight.round_dp(WEIGHT_SCALE)),
                        ..set
                    })
                    .collect(),
                ..exercise
            })
        })
        .collect()
}

fn in_range(a_value: Option<i32>, a_min: i32, a_max: i32) -> bool
{
    a_value.is_none_or(|value| (a_min..=a_max).contains(&value))
}

fn weight_in_range(a_value: Option<Decimal>) -> bool
{
    a_value.is_none_or(|value| value >= Decimal::ZERO && value <= Decimal::from(1000))
}

fn weekday_mask(a_weekdays: &[u32]) -> Result<i32, ApiError>
{
    a_weekdays.iter().try_fold(0, |mask, weekday| {
        if (1..=7).contains(weekday)
        {
            Ok(mask | (1 << (weekday - 1)))
        }
        else
        {
            Err(ApiError::Validation("weekdays"))
        }
    })
}

fn weekdays_of(a_mask: i32) -> Vec<u32>
{
    (1..=7).filter(|weekday| a_mask & (1 << (weekday - 1)) != 0).collect()
}

async fn visible_exercises(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_ids: &[Uuid],
) -> Result<HashMap<Uuid, f64>, ApiError>
{
    let unique: Vec<Uuid> = a_ids.iter().copied().collect::<HashSet<_>>().into_iter().collect();
    let rows = sqlx::query!(
        r#"
        SELECT id, met_val::float8 AS "met!"
        FROM dict_exs
        WHERE id = ANY($1) AND (NOT is_custom OR created_by = $2)
        "#,
        &unique,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    if rows.len() != unique.len()
    {
        return Err(ApiError::Validation("ex_id"));
    }
    Ok(rows.into_iter().map(|row| (row.id, row.met)).collect())
}

async fn save_days(a_conn: &mut PgConnection, a_program_id: Uuid, a_days: &[ProgramDayDto]) -> Result<(), ApiError>
{
    let existing: HashSet<Uuid> =
        sqlx::query_scalar!("SELECT id FROM program_days WHERE program_id = $1", a_program_id)
            .fetch_all(&mut *a_conn)
            .await?
            .into_iter()
            .collect();
    let kept: Vec<Uuid> = a_days
        .iter()
        .filter_map(|day| day.id)
        .filter(|id| existing.contains(id))
        .collect();
    sqlx::query!(
        "DELETE FROM program_days WHERE program_id = $1 AND NOT (id = ANY($2))",
        a_program_id,
        &kept
    )
    .execute(&mut *a_conn)
    .await?;

    for (position, day) in a_days.iter().enumerate()
    {
        let mask = weekday_mask(&day.weekdays)?;
        let day_id = match day.id.filter(|id| existing.contains(id))
        {
            Some(day_id) =>
            {
                sqlx::query!(
                    r#"
                    UPDATE program_days SET position = $2, name = $3, rest_days_after = $4, weekday_mask = $5
                    WHERE id = $1
                    "#,
                    day_id,
                    position as i32,
                    day.name,
                    day.rest_days_after,
                    mask
                )
                .execute(&mut *a_conn)
                .await?;
                sqlx::query!("DELETE FROM program_exercises WHERE day_id = $1", day_id)
                    .execute(&mut *a_conn)
                    .await?;
                day_id
            }
            None =>
            {
                sqlx::query_scalar!(
                    r#"
                    INSERT INTO program_days (program_id, position, name, rest_days_after, weekday_mask)
                    VALUES ($1, $2, $3, $4, $5)
                    RETURNING id
                    "#,
                    a_program_id,
                    position as i32,
                    day.name,
                    day.rest_days_after,
                    mask
                )
                .fetch_one(&mut *a_conn)
                .await?
            }
        };

        for (ex_position, exercise) in day.exercises.iter().enumerate()
        {
            sqlx::query!(
                r#"
                INSERT INTO program_exercises
                    (day_id, position, ex_id, sets, reps_min, reps_max, duration_sec, weight_kg, rest_sec, weight_step, note)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                "#,
                day_id,
                ex_position as i32,
                exercise.ex_id,
                exercise.sets,
                exercise.reps_min,
                exercise.reps_max,
                exercise.duration_sec,
                exercise.weight_kg,
                exercise.rest_sec,
                exercise.weight_step,
                exercise.note
            )
            .execute(&mut *a_conn)
            .await?;
        }
    }

    Ok(())
}

async fn load_days(a_conn: &mut PgConnection, a_program_id: Uuid) -> Result<Vec<DayRow>, ApiError>
{
    Ok(sqlx::query_as!(
        DayRow,
        r#"
        SELECT id, name, rest_days_after, weekday_mask
        FROM program_days WHERE program_id = $1 ORDER BY position
        "#,
        a_program_id
    )
    .fetch_all(&mut *a_conn)
    .await?)
}

async fn load_program(a_conn: &mut PgConnection, a_user_id: Uuid, a_program_id: Uuid) -> Result<ProgramDto, ApiError>
{
    let program = sqlx::query_as!(
        ProgramRow,
        r#"
        SELECT id, name, schedule_mode AS "schedule_mode: ScheduleMode", is_active, created_ts
        FROM training_programs WHERE id = $1 AND user_id = $2
        "#,
        a_program_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    let days = load_days(a_conn, a_program_id).await?;
    let day_ids: Vec<Uuid> = days.iter().map(|day| day.id).collect();
    let exercises = sqlx::query_as!(
        ProgramExRow,
        r#"
        SELECT day_id, ex_id, sets, reps_min, reps_max, duration_sec, weight_kg, rest_sec, weight_step, note
        FROM program_exercises WHERE day_id = ANY($1) ORDER BY day_id, position
        "#,
        &day_ids
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(ProgramDto {
        id: program.id,
        name: program.name,
        schedule_mode: program.schedule_mode,
        is_active: program.is_active,
        created_ts: program.created_ts,
        days: days
            .into_iter()
            .map(|day| ProgramDayDto {
                id: Some(day.id),
                weekdays: weekdays_of(day.weekday_mask),
                exercises: exercises
                    .iter()
                    .filter(|exercise| exercise.day_id == day.id)
                    .map(|exercise| ProgramExerciseDto {
                        ex_id: exercise.ex_id,
                        sets: exercise.sets,
                        reps_min: exercise.reps_min,
                        reps_max: exercise.reps_max,
                        duration_sec: exercise.duration_sec,
                        weight_kg: exercise.weight_kg,
                        rest_sec: exercise.rest_sec,
                        weight_step: exercise.weight_step,
                        note: exercise.note.clone(),
                    })
                    .collect(),
                name: day.name,
                rest_days_after: day.rest_days_after,
            })
            .collect(),
    })
}

async fn prefill_session(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_session_id: Uuid,
    a_day_id: Uuid,
    a_started_ts: DateTime<Utc>,
) -> Result<(), ApiError>
{
    let planned = sqlx::query_as!(
        ProgramExRow,
        r#"
        SELECT day_id, ex_id, sets, reps_min, reps_max, duration_sec, weight_kg, rest_sec, weight_step, note
        FROM program_exercises WHERE day_id = $1 ORDER BY position
        "#,
        a_day_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let ex_ids: Vec<Uuid> = planned.iter().map(|exercise| exercise.ex_id).collect();
    let previous = load_previous(a_conn, a_user_id, a_session_id, Some(a_day_id), a_started_ts, &ex_ids).await?;

    for (position, exercise) in planned.iter().enumerate()
    {
        let last = previous
            .get(&exercise.ex_id)
            .map(|(_, sets)| sets.as_slice())
            .unwrap_or_default();
        let sets = (0..exercise.sets as usize)
            .map(|index| {
                let before = last.get(index).or(last.last());
                SessionSetDto {
                    reps: before
                        .and_then(|set| set.reps)
                        .or(exercise.reps_max)
                        .or(exercise.reps_min),
                    weight_kg: before.and_then(|set| set.weight_kg).or(exercise.weight_kg),
                    duration_sec: before.and_then(|set| set.duration_sec).or(exercise.duration_sec),
                    is_done: false,
                }
            })
            .collect();
        let session_exercise = SaveSessionExercise {
            ex_id: exercise.ex_id,
            reps_min: exercise.reps_min,
            reps_max: exercise.reps_max,
            duration_sec: exercise.duration_sec,
            target_weight: exercise.weight_kg,
            rest_sec: exercise.rest_sec,
            sets,
        };
        insert_session_exercise(a_conn, a_session_id, position as i32, &session_exercise).await?;
    }
    Ok(())
}

async fn insert_session_exercise(
    a_conn: &mut PgConnection,
    a_session_id: Uuid,
    a_position: i32,
    a_exercise: &SaveSessionExercise,
) -> Result<(), ApiError>
{
    let exercise_id = sqlx::query_scalar!(
        r#"
        INSERT INTO session_exercises (session_id, position, ex_id, reps_min, reps_max, duration_sec, target_weight, rest_sec)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id
        "#,
        a_session_id,
        a_position,
        a_exercise.ex_id,
        a_exercise.reps_min,
        a_exercise.reps_max,
        a_exercise.duration_sec,
        a_exercise.target_weight,
        a_exercise.rest_sec
    )
    .fetch_one(&mut *a_conn)
    .await?;

    for (index, set) in a_exercise.sets.iter().enumerate()
    {
        sqlx::query!(
            r#"
            INSERT INTO session_sets (session_exercise_id, set_index, reps, weight_kg, duration_sec, is_done)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
            exercise_id,
            index as i32,
            set.reps,
            set.weight_kg,
            set.duration_sec,
            set.is_done
        )
        .execute(&mut *a_conn)
        .await?;
    }
    Ok(())
}

async fn load_previous(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_session_id: Uuid,
    a_day_id: Option<Uuid>,
    a_before: DateTime<Utc>,
    a_ex_ids: &[Uuid],
) -> Result<HashMap<Uuid, (DateTime<Utc>, Vec<SessionSetDto>)>, ApiError>
{
    let rows = sqlx::query_as!(
        PreviousRow,
        r#"
        SELECT DISTINCT ON (se.ex_id) se.ex_id, se.id AS session_exercise_id, s.started_ts
        FROM session_exercises se
        JOIN workout_sessions s ON s.id = se.session_id
        WHERE s.user_id = $1 AND s.id <> $2 AND s.finished_ts IS NOT NULL AND s.started_ts < $3
          AND se.ex_id = ANY($4)
          AND EXISTS (SELECT 1 FROM session_sets ss WHERE ss.session_exercise_id = se.id AND ss.is_done)
        ORDER BY se.ex_id, (s.day_id IS NOT DISTINCT FROM $5) DESC, s.started_ts DESC, se.position
        "#,
        a_user_id,
        a_session_id,
        a_before,
        a_ex_ids,
        a_day_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let ids: Vec<Uuid> = rows.iter().map(|row| row.session_exercise_id).collect();
    let sets = sqlx::query_as!(
        SetRow,
        r#"
        SELECT session_exercise_id, reps, weight_kg, duration_sec, is_done
        FROM session_sets WHERE session_exercise_id = ANY($1) AND is_done
        ORDER BY session_exercise_id, set_index
        "#,
        &ids
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| {
            let done = sets
                .iter()
                .filter(|set| set.session_exercise_id == row.session_exercise_id)
                .map(set_dto)
                .collect();
            (row.ex_id, (row.started_ts, done))
        })
        .collect())
}

fn set_dto(a_row: &SetRow) -> SessionSetDto
{
    SessionSetDto {
        reps: a_row.reps,
        weight_kg: a_row.weight_kg,
        duration_sec: a_row.duration_sec,
        is_done: a_row.is_done,
    }
}

async fn load_session_row(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_session_id: Uuid,
) -> Result<SessionRow, ApiError>
{
    sqlx::query_as!(
        SessionRow,
        r#"
        SELECT id, program_id, program_name, day_id, day_name, started_ts, finished_ts, intensity, kcal, note, status_mark_id
        FROM workout_sessions WHERE id = $1 AND user_id = $2
        "#,
        a_session_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)
}

async fn load_session(a_conn: &mut PgConnection, a_user_id: Uuid, a_session_id: Uuid) -> Result<SessionDto, ApiError>
{
    let session = load_session_row(a_conn, a_user_id, a_session_id).await?;
    let exercises = sqlx::query_as!(
        SessionExRow,
        r#"
        SELECT se.id, se.ex_id, e.code AS ex_code, e.name AS ex_name, e.type AS "ex_type: ExType", se.reps_min, se.reps_max,
               se.duration_sec, se.target_weight, se.rest_sec
        FROM session_exercises se JOIN dict_exs e ON e.id = se.ex_id
        WHERE se.session_id = $1
        ORDER BY se.position
        "#,
        a_session_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let ids: Vec<Uuid> = exercises.iter().map(|exercise| exercise.id).collect();
    let sets = sqlx::query_as!(
        SetRow,
        r#"
        SELECT session_exercise_id, reps, weight_kg, duration_sec, is_done
        FROM session_sets WHERE session_exercise_id = ANY($1)
        ORDER BY session_exercise_id, set_index
        "#,
        &ids
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let ex_ids: Vec<Uuid> = exercises.iter().map(|exercise| exercise.ex_id).collect();
    let previous = load_previous(
        a_conn,
        a_user_id,
        a_session_id,
        session.day_id,
        session.started_ts,
        &ex_ids,
    )
    .await?;

    Ok(SessionDto {
        id: session.id,
        program_id: session.program_id,
        program_name: session.program_name,
        day_id: session.day_id,
        day_name: session.day_name,
        started_ts: session.started_ts,
        finished_ts: session.finished_ts,
        intensity: session.intensity,
        kcal: session.kcal,
        note: session.note,
        exercises: exercises
            .into_iter()
            .map(|exercise| {
                let (previous_ts, previous_sets) = previous
                    .get(&exercise.ex_id)
                    .map(|(ts, sets)| (Some(*ts), sets.clone()))
                    .unwrap_or_default();
                SessionExerciseDto {
                    sets: sets
                        .iter()
                        .filter(|set| set.session_exercise_id == exercise.id)
                        .map(set_dto)
                        .collect(),
                    ex_id: exercise.ex_id,
                    ex_code: exercise.ex_code,
                    ex_name: exercise.ex_name,
                    ex_type: exercise.ex_type,
                    reps_min: exercise.reps_min,
                    reps_max: exercise.reps_max,
                    duration_sec: exercise.duration_sec,
                    target_weight: exercise.target_weight,
                    rest_sec: exercise.rest_sec,
                    previous: previous_sets,
                    previous_ts,
                }
            })
            .collect(),
    })
}

async fn update_kcal(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_session_id: Uuid,
    a_started_ts: DateTime<Utc>,
    a_finished_ts: DateTime<Utc>,
    a_intensity: i32,
) -> Result<(), ApiError>
{
    let weight = sqlx::query_scalar!(
        r#"
        SELECT v.value FROM body_values v JOIN body_entries e ON e.id = v.entry_id
        WHERE e.user_id = $1 AND v.metric = 'weight' AND e.measured_ts <= $2
        ORDER BY e.measured_ts DESC LIMIT 1
        "#,
        a_user_id,
        a_finished_ts
    )
    .fetch_optional(&mut *a_conn)
    .await?;

    let loads = sqlx::query!(
        r#"
        SELECT e.met_val::float8 AS "met!",
               (SELECT COUNT(*) FROM session_sets ss WHERE ss.session_exercise_id = se.id AND ss.is_done) AS "done!"
        FROM session_exercises se JOIN dict_exs e ON e.id = se.ex_id
        WHERE se.session_id = $1
        "#,
        a_session_id
    )
    .fetch_all(&mut *a_conn)
    .await?
    .into_iter()
    .map(|row| ExerciseLoad {
        met: row.met,
        done_sets: row.done.max(0) as u32,
    })
    .collect::<Vec<_>>();

    let hours = (a_finished_ts - a_started_ts).num_seconds() as f64 / 3600.0;
    let kcal = weight
        .and_then(|weight| weight.to_f64())
        .map(|weight| session_kcal(average_met(&loads), a_intensity, weight, hours))
        .and_then(Decimal::from_f64_retain)
        .map(|kcal| kcal.round_dp(1));

    sqlx::query!(
        "UPDATE workout_sessions SET kcal = $2 WHERE id = $1",
        a_session_id,
        kcal
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

async fn load_summaries(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_limit: i64,
    a_is_finished_only: bool,
) -> Result<Vec<SessionSummaryDto>, ApiError>
{
    Ok(sqlx::query_as!(
        SessionSummaryDto,
        r#"
        SELECT s.id, s.program_name, s.day_name, s.started_ts, s.finished_ts, s.kcal,
               COUNT(ss.session_exercise_id) FILTER (WHERE ss.is_done) AS "done_sets!",
               COALESCE(SUM(ss.weight_kg * ss.reps) FILTER (WHERE ss.is_done), 0) AS "volume_kg!"
        FROM workout_sessions s
        LEFT JOIN session_exercises se ON se.session_id = s.id
        LEFT JOIN session_sets ss ON ss.session_exercise_id = se.id
        WHERE s.user_id = $1 AND (NOT $3 OR s.finished_ts IS NOT NULL)
        GROUP BY s.id
        ORDER BY s.started_ts DESC
        LIMIT $2
        "#,
        a_user_id,
        a_limit,
        a_is_finished_only
    )
    .fetch_all(&mut *a_conn)
    .await?)
}
