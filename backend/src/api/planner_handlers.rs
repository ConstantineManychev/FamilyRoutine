use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, Offset, Timelike, Utc};
use chrono_tz::{Tz, TZ_VARIANTS};
use shared_schema::{
    AgendaDto, AgendaQuery, OccurrenceDto, OccurrenceRefDto, OverloadDto, PlanEventDto, PlanRepeat, PlanSlotDto,
    PlanState, PlanTiming, RoutineStatus, SaveOccurrenceRequest, SavePlanEventRequest, SessionDto,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::training_handlers::{begin_session, load_session, program_plan};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text};
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
    let occurrences = load_occurrences(&mut conn, a_user.user_id, a_query.from, a_query.to)
        .await?
        .into_iter()
        .filter(|occurrence| occurrence.start_ts < high && occurrence.end_ts > low)
        .collect();

    Ok(Json(AgendaDto { occurrences }))
}

pub async fn list_events(State(a_state): State<AppState>, a_user: AuthUser)
    -> Result<Json<Vec<PlanEventDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let events = load_events(&mut conn, a_user.user_id, None).await?;
    Ok(Json(events.into_iter().map(EventRow::into_dto).collect()))
}

pub async fn get_event(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<PlanEventDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_event(&mut conn, a_user.user_id, a_id)
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
    let clean = clean_event(&mut tx, a_user.user_id, &a_req).await?;
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM plan_events WHERE user_id = $1"#,
        a_user.user_id
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
        a_user.user_id,
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

    let event = load_event(&mut tx, a_user.user_id, id).await?;
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
    load_event(&mut tx, a_user.user_id, a_id).await?;
    let clean = clean_event(&mut tx, a_user.user_id, &a_req).await?;

    sqlx::query!(
        r#"
        UPDATE plan_events
        SET title = $3, note = $4, category = $5, timing = $6, start_date = $7, start_time = $8, window_min = $9,
            duration_min = $10, tz = $11, repeat = $12, repeat_every = $13, weekday_mask = $14, until_date = $15,
            program_id = $16, day_id = $17, updated_ts = NOW()
        WHERE id = $1 AND user_id = $2
        "#,
        a_id,
        a_user.user_id,
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

    let event = load_event(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(event.into_dto()))
}

pub async fn delete_event(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM plan_events WHERE id = $1 AND user_id = $2",
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

pub async fn save_occurrence(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_date)): ApiPath<(Uuid, NaiveDate)>,
    ApiJson(a_req): ApiJson<SaveOccurrenceRequest>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let event = load_event(&mut tx, a_user.user_id, a_id).await?;
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
    sqlx::query!(
        r#"
        DELETE FROM plan_instances
        WHERE event_id = $1 AND occ_date = $2 AND state = 'planned' AND moved_date IS NULL AND session_id IS NULL
        "#,
        a_id,
        a_date
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn start_occurrence(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_date)): ApiPath<(Uuid, NaiveDate)>,
) -> Result<(StatusCode, Json<SessionDto>), ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let event = load_event(&mut tx, a_user.user_id, a_id).await?;
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
            program_plan(&mut tx, a_user.user_id, Some(program_id), offset, PLAN_HORIZON_DAYS)
                .await?
                .and_then(|(_, upcoming)| upcoming.first().map(|planned| planned.day_id))
        }
    };

    let session_id = begin_session(&mut tx, a_user.user_id, day_id, None).await?;
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

    let dto = load_session(&mut tx, a_user.user_id, session_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(dto)))
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
    Ok(())
}

pub async fn reopen_session_slot(a_conn: &mut PgConnection, a_session_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        "UPDATE plan_instances SET state = 'planned', done_ts = NULL, updated_ts = NOW() WHERE session_id = $1",
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
            e.id, e.title, e.note, e.category AS "category: RoutineStatus", e.timing AS "timing: PlanTiming",
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

async fn load_occurrences(
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
               COALESCE(s.finished_ts IS NULL AND s.id IS NOT NULL, FALSE) AS "is_session_active!"
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
