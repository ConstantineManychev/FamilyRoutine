use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use shared_schema::{
    CreateMarkRequest, LinkMarkMealsRequest, MarkDetailsDto, MarkDetailsQuery, MarkMealsDto, PersonQuery, PlanState,
    RoutineStatus, StatusMarkDto, TimelineDto, TimelineMemberDto, TimelineQuery, UpdateMarkRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::nutrition_handlers::{load_norm, mark_entries, require_meal_mark};
use crate::api::planner_handlers::{load_occurrences, mark_plan, reopen_plan_by_mark};
use crate::api::study_handlers::mark_study;
use crate::api::training_handlers::load_session;
use crate::api::work_handlers::mark_work;
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_optional_text;
use crate::notify::replan;
use crate::security::authz::require_member;
use crate::security::profile_access::{acting_for, is_editor, require_editor};
use crate::services::nutrition::sum;
use crate::state::AppState;

const MAX_NOTE_LEN: usize = 200;
const MAX_PAST_DAYS: i64 = 31;
const MAX_FUTURE_HOURS: i64 = 24;
const MAX_TIMELINE_DAYS: i64 = 32;
const MAX_RECENT_MARKS: i64 = 2000;
const MAX_LINKED_ENTRIES: usize = 100;
const MAX_TZ_OFFSET_MIN: i32 = 840;

struct MarkRow
{
    id: Uuid,
    user_id: Uuid,
    status: RoutineStatus,
    note: Option<String>,
    start_ts: DateTime<Utc>,
    end_ts: Option<DateTime<Utc>>,
}

struct OwnedMarkRow
{
    id: Uuid,
    user_id: Uuid,
    status: RoutineStatus,
    note: Option<String>,
    start_ts: DateTime<Utc>,
    end_ts: Option<DateTime<Utc>>,
    first_name: String,
    last_name: String,
}

struct MemberRow
{
    user_id: Uuid,
    first_name: String,
    last_name: String,
    is_managed: bool,
    can_edit: bool,
}

pub async fn create_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CreateMarkRequest>,
) -> Result<(StatusCode, Json<StatusMarkDto>), ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let now = Utc::now();
    let start = a_req.start_ts.unwrap_or(now);

    if start < now - Duration::days(MAX_PAST_DAYS) || start > now + Duration::hours(MAX_FUTURE_HOURS)
    {
        return Err(ApiError::Validation("start_ts"));
    }
    if a_req.end_ts.is_some_and(|end| end <= start)
    {
        return Err(ApiError::Validation("end_ts"));
    }

    let mut tx = a_state.db.begin().await?;
    let person_id = acting_for(&mut tx, a_user.user_id, a_req.person_id).await?;
    lock_user_marks(&mut tx, person_id).await?;

    let recent = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM status_marks WHERE user_id = $1 AND start_ts > $2"#,
        person_id,
        now - Duration::days(MAX_PAST_DAYS + 1)
    )
    .fetch_one(&mut *tx)
    .await?;
    if recent >= MAX_RECENT_MARKS
    {
        return Err(ApiError::Validation("marks"));
    }

    let mark = place_mark(&mut tx, person_id, a_req.status, note, start, a_req.end_ts).await?;

    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(mark)))
}

pub async fn update_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<UpdateMarkRequest>,
) -> Result<Json<StatusMarkDto>, ApiError>
{
    let note = clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?;
    let mut tx = a_state.db.begin().await?;
    let owner_id = mark_owner(&mut tx, a_user.user_id, a_id).await?;
    lock_user_marks(&mut tx, owner_id).await?;
    let current = sqlx::query_as!(
        StatusMarkDto,
        r#"
        SELECT id, status AS "status: RoutineStatus", note, start_ts, end_ts
        FROM status_marks
        WHERE id = $1 AND user_id = $2
        FOR UPDATE
        "#,
        a_id,
        owner_id
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(ApiError::NotFound)?;

    let is_time_change = a_req.start_ts.is_some() || a_req.end_ts.is_some() || a_req.is_open_end;
    let (start, end) = if is_time_change
    {
        let start = a_req.start_ts.unwrap_or(current.start_ts);
        let end = if a_req.is_open_end
        {
            None
        }
        else
        {
            a_req.end_ts.or(current.end_ts)
        };
        reschedule(&mut tx, owner_id, a_id, start, end).await?
    }
    else
    {
        (current.start_ts, current.end_ts)
    };

    if current.status == RoutineStatus::Meal && a_req.status != RoutineStatus::Meal
    {
        sqlx::query!(
            "UPDATE meal_entries SET status_mark_id = NULL WHERE user_id = $1 AND status_mark_id = $2",
            owner_id,
            a_id
        )
        .execute(&mut *tx)
        .await?;
    }

    let updated = sqlx::query_as!(
        StatusMarkDto,
        r#"
        UPDATE status_marks SET status = $3, note = $4, start_ts = $5, end_ts = $6
        WHERE id = $1 AND user_id = $2
        RETURNING id, status AS "status: RoutineStatus", note, start_ts, end_ts
        "#,
        a_id,
        owner_id,
        a_req.status as RoutineStatus,
        note,
        start,
        end
    )
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(Json(updated))
}

async fn reschedule(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_id: Uuid,
    a_start: DateTime<Utc>,
    a_end: Option<DateTime<Utc>>,
) -> Result<(DateTime<Utc>, Option<DateTime<Utc>>), ApiError>
{
    let now = Utc::now();
    if a_start < now - Duration::days(MAX_PAST_DAYS) || a_start > now + Duration::hours(MAX_FUTURE_HOURS)
    {
        return Err(ApiError::Validation("start_ts"));
    }
    if a_end.is_some_and(|end| end <= a_start || end > now + Duration::hours(MAX_FUTURE_HOURS))
    {
        return Err(ApiError::Validation("end_ts"));
    }

    let inside = sqlx::query!(
        r#"
        SELECT id, start_ts, end_ts
        FROM status_marks
        WHERE user_id = $1 AND id <> $2 AND start_ts >= $3 AND ($4::timestamptz IS NULL OR start_ts < $4)
        ORDER BY start_ts
        "#,
        a_user_id,
        a_id,
        a_start,
        a_end
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let end = match a_end
    {
        None => match inside.first()
        {
            Some(next) if next.start_ts == a_start => return Err(ApiError::Conflict("MARK_OVERLAP")),
            Some(next) => Some(next.start_ts),
            None => None,
        },
        Some(end) =>
        {
            if inside
                .iter()
                .any(|mark| mark.end_ts.is_some_and(|mark_end| mark_end <= end))
            {
                return Err(ApiError::Conflict("MARK_OVERLAP"));
            }
            if let Some(next) = inside.first()
            {
                sqlx::query!("UPDATE status_marks SET start_ts = $2 WHERE id = $1", next.id, end)
                    .execute(&mut *a_conn)
                    .await?;
            }
            Some(end)
        }
    };

    sqlx::query!(
        r#"
        UPDATE status_marks SET end_ts = $3
        WHERE user_id = $1 AND id <> $2 AND start_ts < $3 AND (end_ts IS NULL OR end_ts > $3)
        "#,
        a_user_id,
        a_id,
        a_start
    )
    .execute(&mut *a_conn)
    .await?;

    Ok((a_start, end))
}

pub async fn current_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<PersonQuery>,
) -> Result<Json<Option<StatusMarkDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let person_id = acting_for(&mut conn, a_user.user_id, a_query.person_id).await?;
    let mark = sqlx::query_as!(
        StatusMarkDto,
        r#"
        SELECT id, status AS "status: RoutineStatus", note, start_ts, end_ts
        FROM status_marks
        WHERE user_id = $1 AND start_ts <= NOW() AND (end_ts IS NULL OR end_ts > NOW())
        ORDER BY start_ts DESC
        LIMIT 1
        "#,
        person_id
    )
    .fetch_optional(&mut *conn)
    .await?;
    Ok(Json(mark))
}

pub async fn mark_details(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<MarkDetailsQuery>,
) -> Result<Json<MarkDetailsDto>, ApiError>
{
    if a_query.tz_offset_min.abs() > MAX_TZ_OFFSET_MIN
    {
        return Err(ApiError::Validation("tz_offset_min"));
    }
    let mut conn = a_state.db.acquire().await?;
    build_details(&mut conn, a_user.user_id, a_id, a_query.tz_offset_min)
        .await
        .map(Json)
}

pub async fn link_mark_meals(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<LinkMarkMealsRequest>,
) -> Result<Json<MarkDetailsDto>, ApiError>
{
    let mut ids = a_req.entry_ids;
    ids.sort();
    ids.dedup();
    if ids.len() > MAX_LINKED_ENTRIES
    {
        return Err(ApiError::Validation("entry_ids"));
    }

    let mut tx = a_state.db.begin().await?;
    let owner_id = mark_owner(&mut tx, a_user.user_id, a_id).await?;
    require_meal_mark(&mut tx, owner_id, a_id).await?;
    let found = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM meal_entries WHERE user_id = $1 AND id = ANY($2)"#,
        owner_id,
        &ids
    )
    .fetch_one(&mut *tx)
    .await?;
    if usize::try_from(found).ok() != Some(ids.len())
    {
        return Err(ApiError::Validation("entry_ids"));
    }

    sqlx::query!(
        r#"
        UPDATE meal_entries SET status_mark_id = NULL
        WHERE user_id = $1 AND status_mark_id = $2 AND NOT (id = ANY($3))
        "#,
        owner_id,
        a_id,
        &ids
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "UPDATE meal_entries SET status_mark_id = $2 WHERE user_id = $1 AND id = ANY($3)",
        owner_id,
        a_id,
        &ids
    )
    .execute(&mut *tx)
    .await?;

    let details = build_details(&mut tx, a_user.user_id, a_id, 0).await?;
    tx.commit().await?;
    Ok(Json(details))
}

async fn build_details(
    a_conn: &mut PgConnection,
    a_viewer_id: Uuid,
    a_id: Uuid,
    a_tz_offset_min: i32,
) -> Result<MarkDetailsDto, ApiError>
{
    let row = sqlx::query_as!(
        OwnedMarkRow,
        r#"
        SELECT m.id, m.user_id, m.status AS "status: RoutineStatus", m.note, m.start_ts, m.end_ts,
               u.first_name, u.last_name
        FROM status_marks m
        JOIN users u ON u.id = m.user_id
        WHERE m.id = $1
        "#,
        a_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    let is_mine = row.user_id == a_viewer_id;
    let can_edit = is_editor(a_conn, a_viewer_id, row.user_id).await?;
    let plan = if can_edit
    {
        mark_plan(a_conn, row.user_id, row.id).await?
    }
    else
    {
        None
    };

    let mut is_details_hidden = false;
    let mut workout = None;
    let mut meals = None;
    let mut work = None;
    let mut study = None;
    match row.status
    {
        RoutineStatus::Gym =>
        {
            let session_id = sqlx::query_scalar!(
                r#"
                SELECT id
                FROM workout_sessions
                WHERE user_id = $1
                  AND (status_mark_id = $2 OR (started_ts >= $3 AND started_ts < COALESCE($4, NOW())))
                ORDER BY (status_mark_id IS NOT DISTINCT FROM $2) DESC, started_ts DESC
                LIMIT 1
                "#,
                row.user_id,
                row.id,
                row.start_ts,
                row.end_ts
            )
            .fetch_optional(&mut *a_conn)
            .await?;
            if let Some(session_id) = session_id
            {
                workout = Some(load_session(a_conn, row.user_id, session_id).await?);
            }
        }
        RoutineStatus::Meal =>
        {
            let entries = mark_entries(a_conn, row.user_id, row.id).await?;
            let (norm, _) = load_norm(a_conn, row.user_id, row.start_ts.date_naive(), row.start_ts).await?;
            meals = Some(MarkMealsDto {
                total: sum(entries.iter().map(|entry| entry.total)),
                entries,
                day_norm: norm.map(|norm| norm.target),
            });
        }
        RoutineStatus::Work if is_mine =>
        {
            let local_day = (row.start_ts + Duration::minutes(i64::from(a_tz_offset_min))).date_naive();
            work = Some(mark_work(a_conn, row.user_id, row.id, local_day).await?);
        }
        RoutineStatus::School if is_mine =>
        {
            study = Some(mark_study(a_conn, row.user_id, row.start_ts, row.end_ts).await?);
        }
        RoutineStatus::Work | RoutineStatus::School => is_details_hidden = !is_mine,
        _ =>
        {}
    }

    Ok(MarkDetailsDto {
        mark: StatusMarkDto {
            id: row.id,
            status: row.status,
            note: row.note,
            start_ts: row.start_ts,
            end_ts: row.end_ts,
        },
        owner_id: row.user_id,
        owner_name: format!("{} {}", row.first_name, row.last_name),
        is_mine,
        can_edit,
        plan,
        is_details_hidden,
        workout,
        meals,
        work,
        study,
    })
}

pub async fn delete_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    let owner_id = mark_owner(&mut tx, a_user.user_id, a_id).await?;
    let is_plan_reopened = reopen_plan_by_mark(&mut tx, a_id).await?.is_some();
    let deleted = sqlx::query!(
        "DELETE FROM status_marks WHERE id = $1 AND user_id = $2",
        a_id,
        owner_id
    )
    .execute(&mut *tx)
    .await?;

    if deleted.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    if is_plan_reopened
    {
        replan(&mut tx, owner_id).await?;
    }
    tx.commit().await?;

    Ok(StatusCode::NO_CONTENT)
}

pub struct MarkLinks
{
    pub has_meals: bool,
    pub has_others: bool,
}

impl MarkLinks
{
    pub fn is_used(&self) -> bool
    {
        self.has_meals || self.has_others
    }
}

pub async fn mark_links(a_conn: &mut PgConnection, a_mark_id: Uuid) -> Result<MarkLinks, ApiError>
{
    let links = sqlx::query!(
        r#"
        SELECT EXISTS (SELECT 1 FROM meal_entries WHERE status_mark_id = $1) AS "has_meals!",
               EXISTS (SELECT 1 FROM workout_sessions WHERE status_mark_id = $1)
            OR EXISTS (SELECT 1 FROM work_task_events WHERE status_mark_id = $1) AS "has_others!"
        "#,
        a_mark_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    Ok(MarkLinks {
        has_meals: links.has_meals,
        has_others: links.has_others,
    })
}

pub async fn lift_mark(a_conn: &mut PgConnection, a_user_id: Uuid, a_mark_id: Uuid) -> Result<(), ApiError>
{
    lock_user_marks(a_conn, a_user_id).await?;
    let lifted = sqlx::query!(
        "DELETE FROM status_marks WHERE id = $1 AND user_id = $2 RETURNING start_ts, end_ts",
        a_mark_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    let Some((start, end)) = lifted.and_then(|lifted| lifted.end_ts.map(|end| (lifted.start_ts, end)))
    else
    {
        return Ok(());
    };

    let halves = sqlx::query!(
        r#"
        SELECT before.id AS before_id, after.id AS after_id, after.end_ts AS after_end
        FROM status_marks before
        JOIN status_marks after
          ON after.user_id = before.user_id AND after.start_ts = $3
         AND after.status = before.status AND after.note IS NOT DISTINCT FROM before.note
        WHERE before.user_id = $1 AND before.end_ts = $2
        LIMIT 1
        "#,
        a_user_id,
        start,
        end
    )
    .fetch_optional(&mut *a_conn)
    .await?;
    let Some(halves) = halves
    else
    {
        return Ok(());
    };
    if mark_links(a_conn, halves.after_id).await?.is_used()
    {
        return Ok(());
    }
    sqlx::query!("DELETE FROM status_marks WHERE id = $1", halves.after_id)
        .execute(&mut *a_conn)
        .await?;
    sqlx::query!(
        "UPDATE status_marks SET end_ts = $2 WHERE id = $1",
        halves.before_id,
        halves.after_end
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

pub async fn timeline(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<TimelineQuery>,
) -> Result<Json<TimelineDto>, ApiError>
{
    if a_query.from >= a_query.to || a_query.to - a_query.from > Duration::days(MAX_TIMELINE_DAYS)
    {
        return Err(ApiError::Validation("range"));
    }

    let (family_name, members) = match a_query.family_id
    {
        Some(family_id) =>
        {
            let name = sqlx::query_scalar!("SELECT name FROM families WHERE id = $1", family_id)
                .fetch_one(&a_state.db)
                .await?;
            require_member(&a_state.db, family_id, a_user.user_id).await?;
            let members = sqlx::query_as!(
                MemberRow,
                r#"
                SELECT u.id AS user_id, u.first_name, u.last_name, u.is_managed,
                       can_manage_person($2, u.id) AS "can_edit!"
                FROM family_mems fm
                JOIN users u ON u.id = fm.user_id
                WHERE fm.family_id = $1
                ORDER BY (fm.user_id = $2) DESC, u.is_managed, u.first_name, u.last_name
                "#,
                family_id,
                a_user.user_id
            )
            .fetch_all(&a_state.db)
            .await?;
            (Some(name), members)
        }
        None =>
        {
            let me = sqlx::query_as!(
                MemberRow,
                r#"
                SELECT id AS user_id, first_name, last_name, is_managed, TRUE AS "can_edit!"
                FROM users WHERE id = $1
                "#,
                a_user.user_id
            )
            .fetch_one(&a_state.db)
            .await?;
            (None, vec![me])
        }
    };

    let ids: Vec<Uuid> = members.iter().map(|member| member.user_id).collect();
    let rows = sqlx::query_as!(
        MarkRow,
        r#"
        SELECT id, user_id, status AS "status: RoutineStatus", note, start_ts, end_ts
        FROM status_marks
        WHERE user_id = ANY($1) AND start_ts < $3 AND (end_ts IS NULL OR end_ts > $2)
        ORDER BY user_id, start_ts
        "#,
        &ids,
        a_query.from,
        a_query.to
    )
    .fetch_all(&a_state.db)
    .await?;

    let mut marks_by_user: HashMap<Uuid, Vec<StatusMarkDto>> = HashMap::new();
    for row in rows
    {
        marks_by_user.entry(row.user_id).or_default().push(StatusMarkDto {
            id: row.id,
            status: row.status,
            note: row.note,
            start_ts: row.start_ts,
            end_ts: row.end_ts,
        });
    }

    let mut conn = a_state.db.acquire().await?;
    let mut dtos = Vec::with_capacity(members.len());
    for member in members
    {
        let plans = if member.can_edit
        {
            load_occurrences(
                &mut conn,
                member.user_id,
                a_query.from.date_naive(),
                a_query.to.date_naive(),
            )
            .await?
            .into_iter()
            .filter(|plan| {
                plan.state == PlanState::Planned
                    && plan.session_id.is_none()
                    && plan.start_ts < a_query.to
                    && plan.end_ts > a_query.from
            })
            .collect()
        }
        else
        {
            Vec::new()
        };
        dtos.push(TimelineMemberDto {
            is_me: member.user_id == a_user.user_id,
            marks: marks_by_user.remove(&member.user_id).unwrap_or_default(),
            plans,
            user_id: member.user_id,
            first_name: member.first_name,
            last_name: member.last_name,
            is_managed: member.is_managed,
            can_edit: member.can_edit,
        });
    }

    Ok(Json(TimelineDto {
        family_id: a_query.family_id,
        family_name,
        members: dtos,
    }))
}

pub async fn place_mark(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_status: RoutineStatus,
    a_note: Option<String>,
    a_start: DateTime<Utc>,
    a_end: Option<DateTime<Utc>>,
) -> Result<StatusMarkDto, ApiError>
{
    lock_user_marks(a_conn, a_user_id).await?;

    sqlx::query!(
        "DELETE FROM status_marks WHERE user_id = $1 AND start_ts = $2",
        a_user_id,
        a_start
    )
    .execute(&mut *a_conn)
    .await?;

    let outer = sqlx::query!(
        r#"
        SELECT status AS "status: RoutineStatus", note, end_ts
        FROM status_marks
        WHERE user_id = $1 AND start_ts < $2 AND (end_ts IS NULL OR end_ts > $2)
        ORDER BY start_ts DESC
        LIMIT 1
        "#,
        a_user_id,
        a_start
    )
    .fetch_optional(&mut *a_conn)
    .await?;

    sqlx::query!(
        r#"
        UPDATE status_marks SET end_ts = $2
        WHERE user_id = $1 AND start_ts < $2 AND (end_ts IS NULL OR end_ts > $2)
        "#,
        a_user_id,
        a_start
    )
    .execute(&mut *a_conn)
    .await?;

    let next_start = sqlx::query_scalar!(
        "SELECT MIN(start_ts) FROM status_marks WHERE user_id = $1 AND start_ts > $2",
        a_user_id,
        a_start
    )
    .fetch_one(&mut *a_conn)
    .await?;

    let end = match (a_end, next_start)
    {
        (Some(end), Some(next)) => Some(end.min(next)),
        (end, next) => end.or(next),
    };

    let mark = sqlx::query_as!(
        StatusMarkDto,
        r#"
        INSERT INTO status_marks (user_id, status, note, start_ts, end_ts)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, status AS "status: RoutineStatus", note, start_ts, end_ts
        "#,
        a_user_id,
        a_status as RoutineStatus,
        a_note,
        a_start,
        end
    )
    .fetch_one(&mut *a_conn)
    .await?;

    if let (Some(outer), Some(resume)) = (outer, a_end.filter(|_| end == a_end))
    {
        if outer.end_ts.is_none_or(|outer_end| outer_end > resume)
        {
            sqlx::query!(
                r#"
                INSERT INTO status_marks (user_id, status, note, start_ts, end_ts)
                VALUES ($1, $2, $3, $4, $5)
                "#,
                a_user_id,
                outer.status as RoutineStatus,
                outer.note,
                resume,
                outer.end_ts
            )
            .execute(&mut *a_conn)
            .await?;
        }
    }

    Ok(mark)
}

async fn mark_owner(a_conn: &mut PgConnection, a_viewer_id: Uuid, a_id: Uuid) -> Result<Uuid, ApiError>
{
    let owner_id = sqlx::query_scalar!("SELECT user_id FROM status_marks WHERE id = $1", a_id)
        .fetch_optional(&mut *a_conn)
        .await?
        .ok_or(ApiError::NotFound)?;
    require_editor(a_conn, a_viewer_id, owner_id).await?;
    Ok(owner_id)
}

async fn lock_user_marks(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        "SELECT pg_advisory_xact_lock(hashtext($1::text))",
        format!("marks:{a_user_id}")
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}
