use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Offset, Timelike, Utc};
use chrono_tz::{Tz, TZ_VARIANTS};
use shared_schema::{
    AgendaDto, AgendaQuery, OccurrenceDto, OccurrenceRefDto, OverloadDto, PersonQuery, PlanBlockDto, PlanEventDto,
    PlanRepeat, PlanSlotDto, PlanState, PlanTiming, RoutineStatus, SaveOccurrenceRequest, SavePlanEventRequest,
    SessionDto,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::nutrition_handlers::{consume_mark_entries, release_mark_entries};
use crate::api::routine_handlers::{realize_mark, withdraw_mark};
use crate::api::training_handlers::{begin_session, load_session, program_plan, record_planned_session};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text};
use crate::notify::replan;
use crate::security::profile_access::{acting_for, require_editor};
use crate::services::planner::{analyze, local_date, parse_zone, resolve_local, weekday_bit, Rule, Slot};
use crate::state::AppState;

const MAX_EVENTS_PER_USER: i64 = 300;
const MAX_TITLE_LEN: usize = 100;
const MAX_NOTE_LEN: usize = 500;
const MAX_RANGE_DAYS: i64 = 92;
const RANGE_MARGIN_DAYS: i64 = 2;
const MAX_MOVE_DAYS: i64 = 366;
const MAX_START_YEARS_AWAY: i64 = 10;
const NEXT_SLOT_DAYS: i64 = 14;
const PLAN_HORIZON_DAYS: i64 = 14;
const MIN_DURATION_MIN: i32 = 5;
const MAX_DURATION_MIN: i32 = 1440;
const MAX_REPEAT_EVERY: i32 = 365;
const FULL_WEEK_MASK: i32 = 0b111_1111;
const DAYS_PER_YEAR: i64 = 366;

struct EventRow
{
    id: Uuid,
    owner_id: Uuid,
    title: String,
    note: Option<String>,
    category: Option<RoutineStatus>,
    timing: PlanTiming,
    start_date: NaiveDate,
    start_time: NaiveTime,
    window_min: Option<i32>,
    duration_min: i32,
    tz: String,
    repeat: PlanRepeat,
    repeat_every: i32,
    weekday_mask: i32,
    until_date: Option<NaiveDate>,
    program_id: Option<Uuid>,
    program_name: Option<String>,
    day_id: Option<Uuid>,
    day_name: Option<String>,
}

struct InstanceRow
{
    event_id: Uuid,
    occ_date: NaiveDate,
    state: PlanState,
    moved_date: Option<NaiveDate>,
    moved_time: Option<NaiveTime>,
    session_id: Option<Uuid>,
    status_mark_id: Option<Uuid>,
    is_session_active: bool,
}

struct Draft<'a>
{
    event: &'a EventRow,
    occ_date: NaiveDate,
    date: NaiveDate,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    instance: Option<&'a InstanceRow>,
}

struct CleanEvent
{
    title: String,
    note: Option<String>,
    category: Option<RoutineStatus>,
    window_min: Option<i32>,
    weekday_mask: i32,
}

impl EventRow
{
    fn rule(&self) -> Rule
    {
        Rule {
            start_date: self.start_date,
            repeat: self.repeat,
            every: self.repeat_every,
            weekday_mask: self.weekday_mask,
            until: self.until_date,
        }
    }

    fn zone(&self) -> Tz
    {
        parse_zone(&self.tz).unwrap_or(Tz::UTC)
    }

    fn span_min(&self) -> i32
    {
        self.window_min.unwrap_or(self.duration_min)
    }

    fn into_dto(self) -> PlanEventDto
    {
        PlanEventDto {
            id: self.id,
            owner_id: self.owner_id,
            title: self.title,
            note: self.note,
            category: self.category,
            timing: self.timing,
            start_date: self.start_date,
            start_time: self.start_time,
            window_min: self.window_min,
            duration_min: self.duration_min,
            tz: self.tz,
            repeat: self.repeat,
            repeat_every: self.repeat_every,
            weekday_mask: self.weekday_mask,
            until_date: self.until_date,
            program_id: self.program_id,
            program_name: self.program_name,
            day_id: self.day_id,
            day_name: self.day_name,
        }
    }
}

pub async fn time_zones(_a_user: AuthUser) -> Json<Vec<&'static str>>
{
    Json(TZ_VARIANTS.iter().map(|zone| zone.name()).collect())
}

pub async fn agenda(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<AgendaQuery>,
) -> Result<Json<AgendaDto>, ApiError>
{
    let viewer = parse_zone(&a_query.tz).ok_or(ApiError::Validation("tz"))?;
    let days = (a_query.to - a_query.from).num_days();
    if !(0..MAX_RANGE_DAYS).contains(&days)
    {
        return Err(ApiError::Validation("to"));
    }

    let low = resolve_local(viewer, a_query.from, NaiveTime::MIN);
    let high = resolve_local(viewer, a_query.to + Duration::days(1), NaiveTime::MIN);
    let mut conn = a_state.db.acquire().await?;
    let owner_id = acting_for(&mut conn, a_user.user_id, a_query.person_id).await?;
    let occurrences = load_occurrences(&mut conn, owner_id, a_query.from, a_query.to)
        .await?
        .into_iter()
        .filter(|occurrence| occurrence.start_ts < high && occurrence.end_ts > low)
        .collect();

    Ok(Json(AgendaDto { occurrences }))
}

pub async fn list_events(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<PersonQuery>,
) -> Result<Json<Vec<PlanEventDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let owner_id = acting_for(&mut conn, a_user.user_id, a_query.person_id).await?;
    let events = load_events(&mut conn, owner_id, None).await?;
    Ok(Json(events.into_iter().map(EventRow::into_dto).collect()))
}

pub async fn get_event(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<PlanEventDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let owner_id = event_owner(&mut conn, a_user.user_id, a_id).await?;
    load_event(&mut conn, owner_id, a_id)
        .await
        .map(|event| Json(event.into_dto()))
}

pub async fn create_event(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SavePlanEventRequest>,
) -> Result<(StatusCode, Json<PlanEventDto>), ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = acting_for(&mut tx, a_user.user_id, a_req.person_id).await?;
    let clean = clean_event(&mut tx, owner_id, &a_req).await?;
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM plan_events WHERE user_id = $1"#,
        owner_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_EVENTS_PER_USER
    {
        return Err(ApiError::Conflict("TOO_MANY_EVENTS"));
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO plan_events (
            user_id, title, note, category, timing, start_date, start_time, window_min, duration_min, tz,
            repeat, repeat_every, weekday_mask, until_date, program_id, day_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
        RETURNING id
        "#,
        owner_id,
        clean.title,
        clean.note,
        clean.category as Option<RoutineStatus>,
        a_req.timing as PlanTiming,
        a_req.start_date,
        a_req.start_time,
        clean.window_min,
        a_req.duration_min,
        a_req.tz,
        a_req.repeat as PlanRepeat,
        a_req.repeat_every,
        clean.weekday_mask,
        a_req.until_date,
        a_req.program_id,
        a_req.day_id
    )
    .fetch_one(&mut *tx)
    .await?;

    replan(&mut tx, owner_id).await?;
    let event = load_event(&mut tx, owner_id, id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(event.into_dto())))
}

pub async fn update_event(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SavePlanEventRequest>,
) -> Result<Json<PlanEventDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = event_owner(&mut tx, a_user.user_id, a_id).await?;
    load_event(&mut tx, owner_id, a_id).await?;
    let clean = clean_event(&mut tx, owner_id, &a_req).await?;

    sqlx::query!(
        r#"
        UPDATE plan_events
        SET title = $3, note = $4, category = $5, timing = $6, start_date = $7, start_time = $8, window_min = $9,
            duration_min = $10, tz = $11, repeat = $12, repeat_every = $13, weekday_mask = $14, until_date = $15,
            program_id = $16, day_id = $17, updated_ts = NOW()
        WHERE id = $1 AND user_id = $2
        "#,
        a_id,
        owner_id,
        clean.title,
        clean.note,
        clean.category as Option<RoutineStatus>,
        a_req.timing as PlanTiming,
        a_req.start_date,
        a_req.start_time,
        clean.window_min,
        a_req.duration_min,
        a_req.tz,
        a_req.repeat as PlanRepeat,
        a_req.repeat_every,
        clean.weekday_mask,
        a_req.until_date,
        a_req.program_id,
        a_req.day_id
    )
    .execute(&mut *tx)
    .await?;

    let event = load_event(&mut tx, owner_id, a_id).await?;
    resync_event_blocks(&mut tx, &event).await?;
    replan(&mut tx, owner_id).await?;
    tx.commit().await?;
    Ok(Json(event.into_dto()))
}

pub async fn delete_event(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = event_owner(&mut tx, a_user.user_id, a_id).await?;
    let planned = sqlx::query_scalar!(
        r#"
        SELECT m.id FROM plan_instances i JOIN status_marks m ON m.id = i.status_mark_id AND m.is_planned
        WHERE i.event_id = $1
        "#,
        a_id
    )
    .fetch_all(&mut *tx)
    .await?;
    drop_planned_marks(&mut tx, &planned).await?;
    let deleted = sqlx::query!("DELETE FROM plan_events WHERE id = $1 AND user_id = $2", a_id, owner_id)
        .execute(&mut *tx)
        .await?;
    if deleted.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    replan(&mut tx, owner_id).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn save_occurrence(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_date)): ApiPath<(Uuid, NaiveDate)>,
    ApiJson(a_req): ApiJson<SaveOccurrenceRequest>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = event_owner(&mut tx, a_user.user_id, a_id).await?;
    let event = load_event(&mut tx, owner_id, a_id).await?;
    if !event.rule().occurs_on(a_date)
    {
        return Err(ApiError::NotFound);
    }

    let requested = match a_req.moved_start
    {
        Some(start) =>
        {
            let local = start.with_timezone(&event.zone()).naive_local();
            let minute = NaiveTime::from_hms_opt(local.hour(), local.minute(), 0).unwrap_or(local.time());
            (Some(local.date()), Some(minute))
        }
        None => (a_req.moved_date, a_req.moved_time),
    };
    let moved = match requested
    {
        (None, None) => None,
        (Some(date), Some(time)) if (date - a_date).num_days().abs() <= MAX_MOVE_DAYS =>
        {
            (date != a_date || time != event.start_time).then_some((date, time))
        }
        (Some(_), Some(_)) => return Err(ApiError::Validation("moved_date")),
        _ => return Err(ApiError::Validation("moved_time")),
    };

    sqlx::query!(
        r#"
        INSERT INTO plan_instances (event_id, occ_date, state, moved_date, moved_time, done_ts, updated_ts)
        VALUES ($1, $2, $3, $4, $5, CASE WHEN $3 = 'done'::plan_state_t THEN NOW() END, NOW())
        ON CONFLICT (event_id, occ_date) DO UPDATE
        SET state = EXCLUDED.state,
            moved_date = EXCLUDED.moved_date,
            moved_time = EXCLUDED.moved_time,
            done_ts = CASE WHEN EXCLUDED.state = 'done' THEN COALESCE(plan_instances.done_ts, NOW()) END,
            updated_ts = NOW()
        "#,
        a_id,
        a_date,
        a_req.state as PlanState,
        moved.map(|(date, _)| date),
        moved.map(|(_, time)| time)
    )
    .execute(&mut *tx)
    .await?;
    sync_plan_mark(&mut tx, a_user.user_id, owner_id, &event, a_date).await?;
    sqlx::query!(
        r#"
        DELETE FROM plan_instances
        WHERE event_id = $1 AND occ_date = $2 AND state = 'planned' AND moved_date IS NULL AND session_id IS NULL
          AND status_mark_id IS NULL
        "#,
        a_id,
        a_date
    )
    .execute(&mut *tx)
    .await?;

    replan(&mut tx, owner_id).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

fn occurrence_span(
    a_event: &EventRow,
    a_occ_date: NaiveDate,
    a_moved_date: Option<NaiveDate>,
    a_moved_time: Option<NaiveTime>,
) -> (DateTime<Utc>, DateTime<Utc>)
{
    let date = a_moved_date.unwrap_or(a_occ_date);
    let time = a_moved_time.unwrap_or(a_event.start_time);
    let start = resolve_local(a_event.zone(), date, time);
    (start, start + Duration::minutes(i64::from(a_event.duration_min)))
}

struct PlanBlockRow
{
    state: PlanState,
    moved_date: Option<NaiveDate>,
    moved_time: Option<NaiveTime>,
    session_id: Option<Uuid>,
    is_session_auto: bool,
    mark_id: Option<Uuid>,
    is_planned: Option<bool>,
    mark_start: Option<DateTime<Utc>>,
    mark_end: Option<DateTime<Utc>>,
}

async fn plan_block(
    a_conn: &mut PgConnection,
    a_event_id: Uuid,
    a_occ_date: NaiveDate,
) -> Result<Option<PlanBlockRow>, ApiError>
{
    Ok(sqlx::query_as!(
        PlanBlockRow,
        r#"
        SELECT i.state AS "state: PlanState", i.moved_date, i.moved_time, i.session_id, i.is_session_auto,
               m.id AS "mark_id?", m.is_planned AS "is_planned?", m.start_ts AS "mark_start?", m.end_ts AS mark_end
        FROM plan_instances i
        LEFT JOIN status_marks m ON m.id = i.status_mark_id
        WHERE i.event_id = $1 AND i.occ_date = $2
        "#,
        a_event_id,
        a_occ_date
    )
    .fetch_optional(&mut *a_conn)
    .await?)
}

async fn insert_planned_mark(
    a_conn: &mut PgConnection,
    a_owner_id: Uuid,
    a_event: &EventRow,
    a_occ_date: NaiveDate,
    a_start: DateTime<Utc>,
    a_end: DateTime<Utc>,
) -> Result<Uuid, ApiError>
{
    let mark_id = sqlx::query_scalar!(
        r#"
        INSERT INTO status_marks (user_id, status, note, start_ts, end_ts, is_planned)
        VALUES ($1, $2, $3, $4, $5, TRUE)
        RETURNING id
        "#,
        a_owner_id,
        a_event.category.unwrap_or(RoutineStatus::Other) as RoutineStatus,
        a_event.title,
        a_start,
        a_end
    )
    .fetch_one(&mut *a_conn)
    .await?;
    sqlx::query!(
        "UPDATE plan_instances SET status_mark_id = $3 WHERE event_id = $1 AND occ_date = $2",
        a_event.id,
        a_occ_date,
        mark_id
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(mark_id)
}

async fn drop_planned_marks(a_conn: &mut PgConnection, a_mark_ids: &[Uuid]) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        DELETE FROM meal_entries
        WHERE status_mark_id IN (SELECT id FROM status_marks WHERE id = ANY($1) AND is_planned)
        "#,
        a_mark_ids
    )
    .execute(&mut *a_conn)
    .await?;
    sqlx::query!("DELETE FROM status_marks WHERE id = ANY($1) AND is_planned", a_mark_ids)
        .execute(&mut *a_conn)
        .await?;
    Ok(())
}

async fn date_mark_entries(
    a_conn: &mut PgConnection,
    a_event: &EventRow,
    a_mark_id: Uuid,
    a_start: DateTime<Utc>,
) -> Result<(), ApiError>
{
    sqlx::query!(
        "UPDATE meal_entries SET eaten_on = $2 WHERE status_mark_id = $1",
        a_mark_id,
        local_date(a_event.zone(), a_start)
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

async fn training_day(a_conn: &mut PgConnection, a_owner_id: Uuid, a_event: &EventRow)
    -> Result<Option<Uuid>, ApiError>
{
    if a_event.day_id.is_some()
    {
        return Ok(a_event.day_id);
    }
    let Some(program_id) = a_event.program_id
    else
    {
        return Ok(None);
    };
    let offset = zone_offset(a_event.zone(), Utc::now());
    Ok(
        program_plan(a_conn, a_owner_id, Some(program_id), offset, PLAN_HORIZON_DAYS)
            .await?
            .and_then(|(_, upcoming)| upcoming.first().map(|planned| planned.day_id)),
    )
}

async fn accept_block(
    a_conn: &mut PgConnection,
    a_actor_id: Uuid,
    a_owner_id: Uuid,
    a_event: &EventRow,
    a_occ_date: NaiveDate,
    a_planned_id: Uuid,
    a_span: (DateTime<Utc>, DateTime<Utc>),
) -> Result<(), ApiError>
{
    let (start, end) = a_span;
    let status = sqlx::query_scalar!(
        r#"SELECT status AS "status: RoutineStatus" FROM status_marks WHERE id = $1"#,
        a_planned_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    let entries = sqlx::query_scalar!("SELECT id FROM meal_entries WHERE status_mark_id = $1", a_planned_id)
        .fetch_all(&mut *a_conn)
        .await?;
    let twin = sqlx::query_scalar!(
        r#"
        SELECT m.id FROM status_marks m
        WHERE m.user_id = $1 AND m.start_ts = $2 AND m.status = $3 AND NOT m.is_planned
          AND NOT EXISTS (SELECT 1 FROM plan_instances i WHERE i.status_mark_id = m.id)
        "#,
        a_owner_id,
        start,
        status as RoutineStatus
    )
    .fetch_optional(&mut *a_conn)
    .await?;

    let mark_id = match twin
    {
        Some(twin_id) =>
        {
            sqlx::query!(
                "UPDATE meal_entries SET status_mark_id = $2 WHERE status_mark_id = $1",
                a_planned_id,
                twin_id
            )
            .execute(&mut *a_conn)
            .await?;
            sqlx::query!(
                "UPDATE work_task_events SET status_mark_id = $2 WHERE status_mark_id = $1",
                a_planned_id,
                twin_id
            )
            .execute(&mut *a_conn)
            .await?;
            sqlx::query!(
                "UPDATE plan_instances SET status_mark_id = $3 WHERE event_id = $1 AND occ_date = $2",
                a_event.id,
                a_occ_date,
                twin_id
            )
            .execute(&mut *a_conn)
            .await?;
            sqlx::query!("DELETE FROM status_marks WHERE id = $1", a_planned_id)
                .execute(&mut *a_conn)
                .await?;
            twin_id
        }
        None =>
        {
            realize_mark(a_conn, a_owner_id, a_planned_id, start, end).await?;
            a_planned_id
        }
    };
    date_mark_entries(a_conn, a_event, mark_id, start).await?;
    consume_mark_entries(a_conn, a_actor_id, &entries).await?;

    if let Some(day_id) = training_day(a_conn, a_owner_id, a_event).await?
    {
        if let Some(session_id) = record_planned_session(a_conn, a_owner_id, day_id, start, end, mark_id).await?
        {
            sqlx::query!(
                r#"
                UPDATE plan_instances SET session_id = $3, is_session_auto = TRUE, done_ts = COALESCE(done_ts, NOW())
                WHERE event_id = $1 AND occ_date = $2
                "#,
                a_event.id,
                a_occ_date,
                session_id
            )
            .execute(&mut *a_conn)
            .await?;
        }
    }
    Ok(())
}

async fn reopen_block(
    a_conn: &mut PgConnection,
    a_owner_id: Uuid,
    a_event: &EventRow,
    a_occ_date: NaiveDate,
    a_block: &PlanBlockRow,
    a_mark_id: Uuid,
    a_span: (DateTime<Utc>, DateTime<Utc>),
) -> Result<(), ApiError>
{
    release_mark_entries(a_conn, a_mark_id).await?;
    if let Some(session_id) = a_block.session_id.filter(|_| a_block.is_session_auto)
    {
        sqlx::query!("DELETE FROM workout_sessions WHERE id = $1", session_id)
            .execute(&mut *a_conn)
            .await?;
        sqlx::query!(
            "UPDATE plan_instances SET is_session_auto = FALSE WHERE event_id = $1 AND occ_date = $2",
            a_event.id,
            a_occ_date
        )
        .execute(&mut *a_conn)
        .await?;
    }
    withdraw_mark(a_conn, a_owner_id, a_mark_id).await?;
    let (start, end) = a_span;
    sqlx::query!(
        "UPDATE status_marks SET start_ts = $2, end_ts = $3 WHERE id = $1",
        a_mark_id,
        start,
        end
    )
    .execute(&mut *a_conn)
    .await?;
    date_mark_entries(a_conn, a_event, a_mark_id, start).await
}

async fn sync_plan_mark(
    a_conn: &mut PgConnection,
    a_actor_id: Uuid,
    a_owner_id: Uuid,
    a_event: &EventRow,
    a_occ_date: NaiveDate,
) -> Result<(), ApiError>
{
    let Some(block) = plan_block(a_conn, a_event.id, a_occ_date).await?
    else
    {
        return Ok(());
    };
    let span = occurrence_span(a_event, a_occ_date, block.moved_date, block.moved_time);
    let is_done = block.state == PlanState::Done;
    let is_session_owned = block.session_id.is_some() && !block.is_session_auto;

    match (block.mark_id, block.is_planned)
    {
        (Some(mark_id), Some(true)) if is_done && !is_session_owned =>
        {
            accept_block(a_conn, a_actor_id, a_owner_id, a_event, a_occ_date, mark_id, span).await
        }
        (Some(mark_id), Some(true)) =>
        {
            if block.mark_start != Some(span.0) || block.mark_end != Some(span.1)
            {
                sqlx::query!(
                    "UPDATE status_marks SET start_ts = $2, end_ts = $3 WHERE id = $1",
                    mark_id,
                    span.0,
                    span.1
                )
                .execute(&mut *a_conn)
                .await?;
                date_mark_entries(a_conn, a_event, mark_id, span.0).await?;
            }
            Ok(())
        }
        (Some(mark_id), Some(false)) if !is_done =>
        {
            reopen_block(a_conn, a_owner_id, a_event, a_occ_date, &block, mark_id, span).await
        }
        (Some(mark_id), Some(false)) if block.mark_start != Some(span.0) =>
        {
            withdraw_mark(a_conn, a_owner_id, mark_id).await?;
            realize_mark(a_conn, a_owner_id, mark_id, span.0, span.1).await?;
            date_mark_entries(a_conn, a_event, mark_id, span.0).await?;
            if let Some(session_id) = block.session_id.filter(|_| block.is_session_auto)
            {
                sqlx::query!(
                    "UPDATE workout_sessions SET started_ts = $2, finished_ts = $3 WHERE id = $1",
                    session_id,
                    span.0,
                    span.1
                )
                .execute(&mut *a_conn)
                .await?;
            }
            Ok(())
        }
        (None, _) if is_done && !is_session_owned =>
        {
            let mark_id = insert_planned_mark(a_conn, a_owner_id, a_event, a_occ_date, span.0, span.1).await?;
            accept_block(a_conn, a_actor_id, a_owner_id, a_event, a_occ_date, mark_id, span).await
        }
        _ => Ok(()),
    }
}

pub async fn ensure_block(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_date)): ApiPath<(Uuid, NaiveDate)>,
) -> Result<Json<PlanBlockDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = event_owner(&mut tx, a_user.user_id, a_id).await?;
    let event = load_event(&mut tx, owner_id, a_id).await?;
    if !event.rule().occurs_on(a_date)
    {
        return Err(ApiError::NotFound);
    }
    sqlx::query!(
        "INSERT INTO plan_instances (event_id, occ_date) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        a_id,
        a_date
    )
    .execute(&mut *tx)
    .await?;
    let block = plan_block(&mut tx, a_id, a_date).await?.ok_or(ApiError::NotFound)?;

    let session_mark = match block.session_id
    {
        Some(session_id) =>
        {
            sqlx::query_scalar!("SELECT status_mark_id FROM workout_sessions WHERE id = $1", session_id)
                .fetch_one(&mut *tx)
                .await?
        }
        None => None,
    };
    let mark_id = match (block.mark_id, session_mark)
    {
        (Some(mark_id), _) | (None, Some(mark_id)) => mark_id,
        (None, None) =>
        {
            let (start, end) = occurrence_span(&event, a_date, block.moved_date, block.moved_time);
            let mark_id = insert_planned_mark(&mut tx, owner_id, &event, a_date, start, end).await?;
            sync_plan_mark(&mut tx, a_user.user_id, owner_id, &event, a_date).await?;
            mark_id
        }
    };
    tx.commit().await?;
    Ok(Json(PlanBlockDto { mark_id }))
}

pub async fn mark_plan(
    a_conn: &mut PgConnection,
    a_owner_id: Uuid,
    a_mark_id: Uuid,
) -> Result<Option<OccurrenceDto>, ApiError>
{
    let link = sqlx::query!(
        r#"
        SELECT i.event_id, i.occ_date, i.moved_date
        FROM plan_instances i
        WHERE i.status_mark_id = $1
        "#,
        a_mark_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    let Some(link) = link
    else
    {
        return Ok(None);
    };
    let day = link.moved_date.unwrap_or(link.occ_date);
    Ok(load_occurrences(a_conn, a_owner_id, day, day)
        .await?
        .into_iter()
        .find(|occurrence| occurrence.event_id == link.event_id && occurrence.occ_date == link.occ_date))
}

async fn resync_event_blocks(a_conn: &mut PgConnection, a_event: &EventRow) -> Result<(), ApiError>
{
    let blocks = sqlx::query!(
        r#"
        SELECT i.occ_date, i.moved_date, i.moved_time, m.id AS mark_id, m.status AS "status: RoutineStatus"
        FROM plan_instances i
        JOIN status_marks m ON m.id = i.status_mark_id AND m.is_planned
        WHERE i.event_id = $1
        "#,
        a_event.id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let status = a_event.category.unwrap_or(RoutineStatus::Other);
    let mut gone = Vec::new();
    for block in blocks
    {
        if !a_event.rule().occurs_on(block.occ_date)
        {
            gone.push(block.mark_id);
            continue;
        }
        if block.status == RoutineStatus::Meal && status != RoutineStatus::Meal
        {
            sqlx::query!("DELETE FROM meal_entries WHERE status_mark_id = $1", block.mark_id)
                .execute(&mut *a_conn)
                .await?;
        }
        let (start, end) = occurrence_span(a_event, block.occ_date, block.moved_date, block.moved_time);
        sqlx::query!(
            "UPDATE status_marks SET status = $2, note = $3, start_ts = $4, end_ts = $5 WHERE id = $1",
            block.mark_id,
            status as RoutineStatus,
            a_event.title,
            start,
            end
        )
        .execute(&mut *a_conn)
        .await?;
        date_mark_entries(a_conn, a_event, block.mark_id, start).await?;
    }
    drop_planned_marks(a_conn, &gone).await
}

async fn drop_session_slot_block(
    a_conn: &mut PgConnection,
    a_event_id: Uuid,
    a_occ_date: NaiveDate,
) -> Result<(), ApiError>
{
    let mark_ids = sqlx::query_scalar!(
        r#"
        SELECT m.id FROM plan_instances i JOIN status_marks m ON m.id = i.status_mark_id AND m.is_planned
        WHERE i.event_id = $1 AND i.occ_date = $2
        "#,
        a_event_id,
        a_occ_date
    )
    .fetch_all(&mut *a_conn)
    .await?;
    drop_planned_marks(a_conn, &mark_ids).await
}

pub async fn start_occurrence(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_date)): ApiPath<(Uuid, NaiveDate)>,
) -> Result<(StatusCode, Json<SessionDto>), ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = event_owner(&mut tx, a_user.user_id, a_id).await?;
    let event = load_event(&mut tx, owner_id, a_id).await?;
    if !event.rule().occurs_on(a_date)
    {
        return Err(ApiError::NotFound);
    }
    let program_id = event.program_id.ok_or(ApiError::Validation("program_id"))?;

    let day_id = match event.day_id
    {
        Some(day_id) => Some(day_id),
        None =>
        {
            let offset = zone_offset(event.zone(), Utc::now());
            program_plan(&mut tx, owner_id, Some(program_id), offset, PLAN_HORIZON_DAYS)
                .await?
                .and_then(|(_, upcoming)| upcoming.first().map(|planned| planned.day_id))
        }
    };

    drop_session_slot_block(&mut tx, a_id, a_date).await?;
    let session_id = begin_session(&mut tx, owner_id, day_id, None).await?;
    sqlx::query!(
        r#"
        INSERT INTO plan_instances (event_id, occ_date, state, session_id, updated_ts)
        VALUES ($1, $2, 'planned', $3, NOW())
        ON CONFLICT (event_id, occ_date) DO UPDATE
        SET state = 'planned', session_id = EXCLUDED.session_id, done_ts = NULL, updated_ts = NOW()
        "#,
        a_id,
        a_date,
        session_id
    )
    .execute(&mut *tx)
    .await?;

    let dto = load_session(&mut tx, owner_id, session_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(dto)))
}

async fn event_owner(a_conn: &mut PgConnection, a_viewer_id: Uuid, a_id: Uuid) -> Result<Uuid, ApiError>
{
    let owner_id = sqlx::query_scalar!("SELECT user_id FROM plan_events WHERE id = $1", a_id)
        .fetch_optional(&mut *a_conn)
        .await?
        .ok_or(ApiError::NotFound)?;
    require_editor(a_conn, a_viewer_id, owner_id).await?;
    Ok(owner_id)
}

pub async fn complete_session_slot(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_session_id: Uuid,
    a_program_id: Option<Uuid>,
    a_started_ts: DateTime<Utc>,
    a_finished_ts: DateTime<Utc>,
) -> Result<(), ApiError>
{
    let linked = sqlx::query!(
        "UPDATE plan_instances SET state = 'done', done_ts = $2, updated_ts = NOW() WHERE session_id = $1",
        a_session_id,
        a_finished_ts
    )
    .execute(&mut *a_conn)
    .await?;
    let planned = sqlx::query_scalar!(
        r#"
        SELECT m.id FROM plan_instances i JOIN status_marks m ON m.id = i.status_mark_id AND m.is_planned
        WHERE i.session_id = $1
        "#,
        a_session_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    drop_planned_marks(a_conn, &planned).await?;
    let Some(program_id) = a_program_id.filter(|_| linked.rows_affected() == 0)
    else
    {
        return Ok(());
    };

    let day = a_started_ts.date_naive();
    let occurrences = load_occurrences(a_conn, a_user_id, day - Duration::days(1), day + Duration::days(1)).await?;
    let slot = occurrences.into_iter().find(|occurrence| {
        occurrence.program_id == Some(program_id)
            && occurrence.state == PlanState::Planned
            && occurrence.session_id.is_none()
            && parse_zone(&occurrence.tz).is_some_and(|zone| local_date(zone, a_started_ts) == occurrence.date)
    });
    let Some(slot) = slot
    else
    {
        return Ok(());
    };

    sqlx::query!(
        r#"
        INSERT INTO plan_instances (event_id, occ_date, state, session_id, done_ts, updated_ts)
        VALUES ($1, $2, 'done', $3, $4, NOW())
        ON CONFLICT (event_id, occ_date) DO UPDATE
        SET state = 'done', session_id = EXCLUDED.session_id, done_ts = EXCLUDED.done_ts, updated_ts = NOW()
        "#,
        slot.event_id,
        slot.occ_date,
        a_session_id,
        a_finished_ts
    )
    .execute(&mut *a_conn)
    .await?;
    drop_session_slot_block(a_conn, slot.event_id, slot.occ_date).await
}

pub async fn reopen_session_slot(a_conn: &mut PgConnection, a_session_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        UPDATE plan_instances SET state = 'planned', done_ts = NULL, is_session_auto = FALSE, updated_ts = NOW()
        WHERE session_id = $1
        "#,
        a_session_id
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

pub async fn next_training_slot(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_viewer: Tz,
    a_now: DateTime<Utc>,
) -> Result<Option<PlanSlotDto>, ApiError>
{
    let today = local_date(a_viewer, a_now);
    let occurrences = load_occurrences(a_conn, a_user_id, today, today + Duration::days(NEXT_SLOT_DAYS)).await?;
    Ok(occurrences
        .into_iter()
        .filter(|occurrence| {
            occurrence.program_id.is_some()
                && occurrence.state == PlanState::Planned
                && (occurrence.session_id.is_none() || occurrence.is_session_active)
                && local_date(a_viewer, occurrence.start_ts) >= today
        })
        .min_by_key(|occurrence| occurrence.start_ts)
        .map(|occurrence| PlanSlotDto {
            event_id: occurrence.event_id,
            occ_date: occurrence.occ_date,
            title: occurrence.title,
            timing: occurrence.timing,
            start_ts: occurrence.start_ts,
            end_ts: occurrence.end_ts,
            duration_min: occurrence.duration_min,
            day_name: occurrence.day_name,
        }))
}

fn zone_offset(a_zone: Tz, a_now: DateTime<Utc>) -> Duration
{
    Duration::seconds(i64::from(a_now.with_timezone(&a_zone).offset().fix().local_minus_utc()))
}

async fn clean_event(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_req: &SavePlanEventRequest,
) -> Result<CleanEvent, ApiError>
{
    let title = clean_text(&a_req.title, 1, MAX_TITLE_LEN, "title")?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    parse_zone(&a_req.tz).ok_or(ApiError::Validation("tz"))?;

    let today = Utc::now().date_naive();
    if (a_req.start_date - today).num_days().abs() > MAX_START_YEARS_AWAY * DAYS_PER_YEAR
    {
        return Err(ApiError::Validation("start_date"));
    }
    if !(MIN_DURATION_MIN..=MAX_DURATION_MIN).contains(&a_req.duration_min)
    {
        return Err(ApiError::Validation("duration_min"));
    }
    let window_min = match a_req.timing
    {
        PlanTiming::Fixed => None,
        PlanTiming::Window =>
        {
            let window = a_req.window_min.ok_or(ApiError::Validation("window_min"))?;
            if !(MIN_DURATION_MIN..=MAX_DURATION_MIN).contains(&window) || window < a_req.duration_min
            {
                return Err(ApiError::Validation("window_min"));
            }
            Some(window)
        }
    };
    if !(1..=MAX_REPEAT_EVERY).contains(&a_req.repeat_every)
    {
        return Err(ApiError::Validation("repeat_every"));
    }
    let weekday_mask = match a_req.repeat
    {
        PlanRepeat::Weekly if a_req.weekday_mask == 0 => weekday_bit(a_req.start_date),
        PlanRepeat::Weekly if (1..=FULL_WEEK_MASK).contains(&a_req.weekday_mask) => a_req.weekday_mask,
        PlanRepeat::Weekly => return Err(ApiError::Validation("weekday_mask")),
        _ => 0,
    };
    if a_req.until_date.is_some_and(|until| until < a_req.start_date)
    {
        return Err(ApiError::Validation("until_date"));
    }

    let category = match a_req.program_id
    {
        Some(program_id) =>
        {
            let is_valid = sqlx::query_scalar!(
                r#"
                SELECT EXISTS (
                    SELECT 1 FROM training_programs p
                    WHERE p.id = $1 AND p.user_id = $2
                      AND ($3::uuid IS NULL OR EXISTS (SELECT 1 FROM program_days d WHERE d.id = $3 AND d.program_id = p.id))
                ) AS "is_valid!"
                "#,
                program_id,
                a_user_id,
                a_req.day_id
            )
            .fetch_one(&mut *a_conn)
            .await?;
            if !is_valid
            {
                return Err(ApiError::Validation("program_id"));
            }
            Some(RoutineStatus::Gym)
        }
        None if a_req.day_id.is_some() => return Err(ApiError::Validation("day_id")),
        None => a_req.category,
    };

    Ok(CleanEvent {
        title,
        note,
        category,
        window_min,
        weekday_mask,
    })
}

async fn load_events(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_only: Option<Uuid>,
) -> Result<Vec<EventRow>, ApiError>
{
    sqlx::query_as!(
        EventRow,
        r#"
        SELECT
            e.id, e.user_id AS owner_id, e.title, e.note, e.category AS "category: RoutineStatus", e.timing AS "timing: PlanTiming",
            e.start_date, e.start_time, e.window_min, e.duration_min, e.tz, e.repeat AS "repeat: PlanRepeat",
            e.repeat_every, e.weekday_mask, e.until_date, e.program_id, p.name AS "program_name?", e.day_id,
            d.name AS "day_name?"
        FROM plan_events e
        LEFT JOIN training_programs p ON p.id = e.program_id
        LEFT JOIN program_days d ON d.id = e.day_id
        WHERE e.user_id = $1 AND ($2::uuid IS NULL OR e.id = $2)
        ORDER BY e.start_time, e.title
        "#,
        a_user_id,
        a_only
    )
    .fetch_all(&mut *a_conn)
    .await
    .map_err(ApiError::from)
}

async fn load_event(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<EventRow, ApiError>
{
    load_events(a_conn, a_user_id, Some(a_id))
        .await?
        .into_iter()
        .next()
        .ok_or(ApiError::NotFound)
}

pub async fn load_occurrences(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_from: NaiveDate,
    a_to: NaiveDate,
) -> Result<Vec<OccurrenceDto>, ApiError>
{
    let from = a_from - Duration::days(RANGE_MARGIN_DAYS);
    let to = a_to + Duration::days(RANGE_MARGIN_DAYS);
    let events = load_events(a_conn, a_user_id, None).await?;
    let instances = sqlx::query_as!(
        InstanceRow,
        r#"
        SELECT i.event_id, i.occ_date, i.state AS "state: PlanState", i.moved_date, i.moved_time, i.session_id,
               i.status_mark_id, COALESCE(s.finished_ts IS NULL AND s.id IS NOT NULL, FALSE) AS "is_session_active!"
        FROM plan_instances i
        JOIN plan_events e ON e.id = i.event_id
        LEFT JOIN workout_sessions s ON s.id = i.session_id
        WHERE e.user_id = $1 AND (i.occ_date BETWEEN $2 AND $3 OR i.moved_date BETWEEN $2 AND $3)
        "#,
        a_user_id,
        from,
        to
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let by_key: HashMap<(Uuid, NaiveDate), &InstanceRow> = instances
        .iter()
        .map(|instance| ((instance.event_id, instance.occ_date), instance))
        .collect();
    let by_event: HashMap<Uuid, &EventRow> = events.iter().map(|event| (event.id, event)).collect();

    let mut drafts = Vec::new();
    for event in &events
    {
        for date in event.rule().dates_between(from, to)
        {
            let instance = by_key.get(&(event.id, date)).copied();
            if instance.is_some_and(|instance| instance.moved_date.is_some())
            {
                continue;
            }
            drafts.push(draft(event, date, date, event.start_time, instance));
        }
    }
    for instance in &instances
    {
        let (Some(event), Some(date), Some(time)) = (
            by_event.get(&instance.event_id),
            instance.moved_date,
            instance.moved_time,
        )
        else
        {
            continue;
        };
        if (from..=to).contains(&date) && event.rule().occurs_on(instance.occ_date)
        {
            drafts.push(draft(event, instance.occ_date, date, time, Some(instance)));
        }
    }

    drafts.sort_by_key(|draft| (draft.start, draft.end));
    let slots: Vec<Slot> = drafts
        .iter()
        .map(|draft| Slot {
            start: draft.start,
            end: draft.end,
            timing: draft.event.timing,
            duration_min: draft.event.duration_min,
            state: draft.instance.map_or(PlanState::Planned, |instance| instance.state),
        })
        .collect();
    let issues = analyze(&slots);

    Ok(drafts
        .iter()
        .zip(issues)
        .zip(&slots)
        .map(|((draft, issues), slot)| OccurrenceDto {
            event_id: draft.event.id,
            occ_date: draft.occ_date,
            date: draft.date,
            title: draft.event.title.clone(),
            note: draft.event.note.clone(),
            category: draft.event.category,
            timing: draft.event.timing,
            start_ts: draft.start,
            end_ts: draft.end,
            duration_min: draft.event.duration_min,
            tz: draft.event.tz.clone(),
            repeat: draft.event.repeat,
            state: slot.state,
            is_moved: draft.date != draft.occ_date
                || draft.instance.is_some_and(|instance| instance.moved_time.is_some()),
            program_id: draft.event.program_id,
            day_name: draft.event.day_name.clone(),
            session_id: draft.instance.and_then(|instance| instance.session_id),
            status_mark_id: draft.instance.and_then(|instance| instance.status_mark_id),
            is_session_active: draft.instance.is_some_and(|instance| instance.is_session_active),
            conflicts: issues
                .conflicts
                .iter()
                .map(|other| OccurrenceRefDto {
                    event_id: drafts[*other].event.id,
                    occ_date: drafts[*other].occ_date,
                    title: drafts[*other].event.title.clone(),
                })
                .collect(),
            overload: issues.overload.map(|overload| OverloadDto {
                window_min: overload.window_min,
                busy_min: overload.busy_min,
            }),
        })
        .collect())
}

fn draft<'a>(
    a_event: &'a EventRow,
    a_occ_date: NaiveDate,
    a_date: NaiveDate,
    a_time: NaiveTime,
    a_instance: Option<&'a InstanceRow>,
) -> Draft<'a>
{
    let start = resolve_local(a_event.zone(), a_date, a_time);
    Draft {
        event: a_event,
        occ_date: a_occ_date,
        date: a_date,
        start,
        end: start + Duration::minutes(i64::from(a_event.span_min())),
        instance: a_instance,
    }
}
