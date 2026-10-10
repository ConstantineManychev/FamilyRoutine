use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use shared_schema::{
    CreateMarkRequest, RoutineSharingRequest, RoutineStatus, StatusMarkDto, TimelineDto, TimelineMemberDto,
    TimelineQuery, UpdateMarkRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_optional_text;
use crate::security::authz::require_member;
use crate::state::AppState;

const MAX_NOTE_LEN: usize = 200;
const MAX_PAST_DAYS: i64 = 31;
const MAX_FUTURE_HOURS: i64 = 24;
const MAX_TIMELINE_DAYS: i64 = 8;
const MAX_RECENT_MARKS: i64 = 2000;

struct MarkRow
{
    id: Uuid,
    user_id: Uuid,
    status: RoutineStatus,
    note: Option<String>,
    start_ts: DateTime<Utc>,
    end_ts: Option<DateTime<Utc>>,
}

struct MemberRow
{
    user_id: Uuid,
    first_name: String,
    last_name: String,
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
    lock_user_marks(&mut tx, a_user.user_id).await?;

    let recent = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM status_marks WHERE user_id = $1 AND start_ts > $2"#,
        a_user.user_id,
        now - Duration::days(MAX_PAST_DAYS + 1)
    )
    .fetch_one(&mut *tx)
    .await?;
    if recent >= MAX_RECENT_MARKS
    {
        return Err(ApiError::Validation("marks"));
    }

    sqlx::query!(
        "DELETE FROM status_marks WHERE user_id = $1 AND start_ts = $2",
        a_user.user_id,
        start
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        r#"
        UPDATE status_marks SET end_ts = $2
        WHERE user_id = $1 AND start_ts < $2 AND (end_ts IS NULL OR end_ts > $2)
        "#,
        a_user.user_id,
        start
    )
    .execute(&mut *tx)
    .await?;

    let next_start = sqlx::query_scalar!(
        "SELECT MIN(start_ts) FROM status_marks WHERE user_id = $1 AND start_ts > $2",
        a_user.user_id,
        start
    )
    .fetch_one(&mut *tx)
    .await?;

    let end = match (a_req.end_ts, next_start)
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
        a_user.user_id,
        a_req.status as RoutineStatus,
        note,
        start,
        end
    )
    .fetch_one(&mut *tx)
    .await?;

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

    sqlx::query_as!(
        StatusMarkDto,
        r#"
        UPDATE status_marks SET status = $3, note = $4
        WHERE id = $1 AND user_id = $2
        RETURNING id, status AS "status: RoutineStatus", note, start_ts, end_ts
        "#,
        a_id,
        a_user.user_id,
        a_req.status as RoutineStatus,
        note
    )
    .fetch_optional(&a_state.db)
    .await?
    .map(Json)
    .ok_or(ApiError::NotFound)
}

pub async fn delete_mark(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM status_marks WHERE id = $1 AND user_id = $2",
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
            require_member(&a_state.db, family_id, a_user.user_id).await?;
            let name = sqlx::query_scalar!("SELECT name FROM families WHERE id = $1", family_id)
                .fetch_one(&a_state.db)
                .await?;
            let members = sqlx::query_as!(
                MemberRow,
                r#"
                SELECT u.id AS user_id, u.first_name, u.last_name
                FROM family_mems fm
                JOIN users u ON u.id = fm.user_id
                WHERE fm.family_id = $1 AND (fm.user_id = $2 OR fm.is_routine_shared)
                ORDER BY (fm.user_id = $2) DESC, u.first_name, u.last_name
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
                "SELECT id AS user_id, first_name, last_name FROM users WHERE id = $1",
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

    let members = members
        .into_iter()
        .map(|member| TimelineMemberDto {
            is_me: member.user_id == a_user.user_id,
            marks: marks_by_user.remove(&member.user_id).unwrap_or_default(),
            user_id: member.user_id,
            first_name: member.first_name,
            last_name: member.last_name,
        })
        .collect();

    Ok(Json(TimelineDto {
        family_id: a_query.family_id,
        family_name,
        members,
    }))
}

pub async fn set_routine_sharing(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_family_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<RoutineSharingRequest>,
) -> Result<StatusCode, ApiError>
{
    let updated = sqlx::query!(
        "UPDATE family_mems SET is_routine_shared = $3 WHERE family_id = $1 AND user_id = $2",
        a_family_id,
        a_user.user_id,
        a_req.is_shared
    )
    .execute(&a_state.db)
    .await?;

    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    Ok(StatusCode::NO_CONTENT)
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
