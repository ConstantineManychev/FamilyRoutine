use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use shared_schema::{
    BlockLogDto, MarkWorkDto, SaveTaskRequest, TaskAction, TaskEventDto, TaskEventKind, TaskField, TaskKind,
    TaskLogRequest, WorkDayDto, WorkDayQuery, WorkTaskDetailsDto, WorkTaskDto,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text};
use crate::state::AppState;

const MAX_TITLE_LEN: usize = 200;
const MAX_NOTE_LEN: usize = 2000;
const MAX_REPORT_LEN: usize = 2000;
const MAX_DAYS_AWAY: i64 = 366;
const MAX_FUTURE_LOG_DAYS: i64 = 1;
const MAX_CREATED_PER_DAY: i64 = 300;
const MAX_EVENTS_PER_TASK: i64 = 1000;

struct TaskRow
{
    id: Uuid,
    kind: TaskKind,
    title: String,
    note: Option<String>,
    start_on: NaiveDate,
    done_on: Option<NaiveDate>,
    done_ts: Option<DateTime<Utc>>,
    deleted_ts: Option<DateTime<Utc>>,
    created_ts: DateTime<Utc>,
    updated_ts: DateTime<Utc>,
    last_report: Option<String>,
    last_report_ts: Option<DateTime<Utc>>,
    report_count: i64,
}

impl From<TaskRow> for WorkTaskDto
{
    fn from(a_row: TaskRow) -> Self
    {
        Self {
            id: a_row.id,
            kind: a_row.kind,
            title: a_row.title,
            note: a_row.note,
            start_on: a_row.start_on,
            done_on: a_row.done_on,
            done_ts: a_row.done_ts,
            deleted_ts: a_row.deleted_ts,
            created_ts: a_row.created_ts,
            updated_ts: a_row.updated_ts,
            last_report: a_row.last_report,
            last_report_ts: a_row.last_report_ts,
            report_count: a_row.report_count,
        }
    }
}

struct CleanTask
{
    kind: TaskKind,
    title: String,
    note: Option<String>,
    date: NaiveDate,
}

fn check_date(a_date: NaiveDate) -> Result<NaiveDate, ApiError>
{
    let today = Utc::now().date_naive();
    if (a_date - today).num_days().abs() > MAX_DAYS_AWAY
    {
        return Err(ApiError::Validation("date"));
    }
    Ok(a_date)
}

fn clean_task(a_req: SaveTaskRequest) -> Result<CleanTask, ApiError>
{
    Ok(CleanTask {
        kind: a_req.kind,
        title: clean_text(&a_req.title, 1, MAX_TITLE_LEN, "title")?,
        note: clean_optional_text(a_req.note.as_deref(), MAX_NOTE_LEN, "note")?,
        date: check_date(a_req.date)?,
    })
}

fn kind_wire(a_kind: TaskKind) -> &'static str
{
    match a_kind
    {
        TaskKind::General => "general",
        TaskKind::Day => "day",
    }
}

async fn day_tasks(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_date: NaiveDate,
) -> Result<(Vec<WorkTaskDto>, Vec<WorkTaskDto>), ApiError>
{
    let rows = sqlx::query_as!(
        TaskRow,
        r#"
        SELECT t.id, t.kind AS "kind: TaskKind", t.title, t.note, t.start_on, t.done_on, t.done_ts, t.deleted_ts,
               t.created_ts, t.updated_ts, r.report AS "last_report?", r.event_ts AS "last_report_ts?",
               (SELECT COUNT(*) FROM work_task_events c WHERE c.task_id = t.id AND c.report IS NOT NULL)
                   AS "report_count!"
        FROM work_tasks t
        LEFT JOIN LATERAL (
            SELECT e.report, e.event_ts FROM work_task_events e
            WHERE e.task_id = t.id AND e.report IS NOT NULL
            ORDER BY e.seq DESC
            LIMIT 1
        ) r ON TRUE
        WHERE t.user_id = $1 AND t.deleted_ts IS NULL
          AND (
              (t.kind = 'general' AND t.start_on <= $2 AND (t.done_on IS NULL OR t.done_on >= $2))
              OR (t.kind = 'day' AND t.start_on = $2)
          )
        ORDER BY t.done_on IS NOT NULL, t.start_on, t.created_ts
        "#,
        a_user_id,
        a_date
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let (general, day): (Vec<WorkTaskDto>, Vec<WorkTaskDto>) = rows
        .into_iter()
        .map(WorkTaskDto::from)
        .partition(|task| task.kind == TaskKind::General);
    Ok((general, day))
}

async fn load_task(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<WorkTaskDto, ApiError>
{
    sqlx::query_as!(
        TaskRow,
        r#"
        SELECT t.id, t.kind AS "kind: TaskKind", t.title, t.note, t.start_on, t.done_on, t.done_ts, t.deleted_ts,
               t.created_ts, t.updated_ts, r.report AS "last_report?", r.event_ts AS "last_report_ts?",
               (SELECT COUNT(*) FROM work_task_events c WHERE c.task_id = t.id AND c.report IS NOT NULL)
                   AS "report_count!"
        FROM work_tasks t
        LEFT JOIN LATERAL (
            SELECT e.report, e.event_ts FROM work_task_events e
            WHERE e.task_id = t.id AND e.report IS NOT NULL
            ORDER BY e.seq DESC
            LIMIT 1
        ) r ON TRUE
        WHERE t.id = $1 AND t.user_id = $2
        "#,
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .map(WorkTaskDto::from)
    .ok_or(ApiError::NotFound)
}

async fn lock_task(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<WorkTaskDto, ApiError>
{
    sqlx::query!(
        "SELECT id FROM work_tasks WHERE id = $1 AND user_id = $2 FOR UPDATE",
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;
    let task = load_task(a_conn, a_user_id, a_id).await?;
    if task.deleted_ts.is_some()
    {
        return Err(ApiError::Conflict("TASK_ARCHIVED"));
    }
    Ok(task)
}

async fn task_events(a_conn: &mut PgConnection, a_task_id: Uuid) -> Result<Vec<TaskEventDto>, ApiError>
{
    Ok(sqlx::query_as!(
        TaskEventDto,
        r#"
        SELECT id, kind AS "kind: TaskEventKind", field AS "field: TaskField", old_value, new_value, report,
               event_on, event_ts, status_mark_id
        FROM work_task_events
        WHERE task_id = $1
        ORDER BY seq
        "#,
        a_task_id
    )
    .fetch_all(&mut *a_conn)
    .await?)
}

async fn details(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<WorkTaskDetailsDto, ApiError>
{
    let task = load_task(a_conn, a_user_id, a_id).await?;
    let events = task_events(a_conn, a_id).await?;
    Ok(WorkTaskDetailsDto { task, events })
}

struct NewEvent<'a>
{
    kind: TaskEventKind,
    field: Option<TaskField>,
    old_value: Option<&'a str>,
    new_value: Option<&'a str>,
    report: Option<&'a str>,
    event_on: NaiveDate,
    status_mark_id: Option<Uuid>,
}

impl<'a> NewEvent<'a>
{
    fn plain(a_kind: TaskEventKind, a_event_on: NaiveDate) -> Self
    {
        Self {
            kind: a_kind,
            field: None,
            old_value: None,
            new_value: None,
            report: None,
            event_on: a_event_on,
            status_mark_id: None,
        }
    }

    fn edit(a_field: TaskField, a_old: Option<&'a str>, a_new: Option<&'a str>, a_event_on: NaiveDate) -> Self
    {
        Self {
            field: Some(a_field),
            old_value: a_old,
            new_value: a_new,
            ..Self::plain(TaskEventKind::Edited, a_event_on)
        }
    }
}

async fn append_event(a_conn: &mut PgConnection, a_task_id: Uuid, a_event: NewEvent<'_>) -> Result<(), ApiError>
{
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM work_task_events WHERE task_id = $1"#,
        a_task_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if count >= MAX_EVENTS_PER_TASK
    {
        return Err(ApiError::Conflict("TOO_MANY_EVENTS"));
    }
    sqlx::query!(
        r#"
        INSERT INTO work_task_events (task_id, kind, field, old_value, new_value, report, event_on, status_mark_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        "#,
        a_task_id,
        a_event.kind as TaskEventKind,
        a_event.field as Option<TaskField>,
        a_event.old_value,
        a_event.new_value,
        a_event.report,
        a_event.event_on,
        a_event.status_mark_id
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

pub async fn work_day(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<WorkDayQuery>,
) -> Result<Json<WorkDayDto>, ApiError>
{
    let date = check_date(a_query.date)?;
    let mut conn = a_state.db.acquire().await?;
    let (general, day) = day_tasks(&mut conn, a_user.user_id, date).await?;
    Ok(Json(WorkDayDto { date, general, day }))
}

pub async fn get_task(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<Json<WorkTaskDetailsDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    details(&mut conn, a_user.user_id, a_id).await.map(Json)
}

pub async fn create_task(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveTaskRequest>,
) -> Result<(StatusCode, Json<WorkTaskDetailsDto>), ApiError>
{
    let task = clean_task(a_req)?;
    let mut tx = a_state.db.begin().await?;
    sqlx::query!("SELECT id FROM users WHERE id = $1 FOR UPDATE", a_user.user_id)
        .fetch_one(&mut *tx)
        .await?;
    let recent = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM work_tasks WHERE user_id = $1 AND created_ts > NOW() - INTERVAL '1 day'"#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if recent >= MAX_CREATED_PER_DAY
    {
        return Err(ApiError::Conflict("TOO_MANY_TASKS"));
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO work_tasks (user_id, kind, title, note, start_on)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id
        "#,
        a_user.user_id,
        task.kind as TaskKind,
        task.title,
        task.note,
        task.date
    )
    .fetch_one(&mut *tx)
    .await?;
    let created = NewEvent {
        new_value: Some(task.title.as_str()),
        ..NewEvent::plain(TaskEventKind::Created, task.date)
    };
    append_event(&mut tx, id, created).await?;
    let details = details(&mut tx, a_user.user_id, id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(details)))
}

pub async fn update_task(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveTaskRequest>,
) -> Result<Json<WorkTaskDetailsDto>, ApiError>
{
    let next = clean_task(a_req)?;
    let mut tx = a_state.db.begin().await?;
    let current = lock_task(&mut tx, a_user.user_id, a_id).await?;
    if current.kind == TaskKind::General && current.done_on.is_some_and(|done| next.date > done)
    {
        return Err(ApiError::Validation("date"));
    }

    let today = Utc::now().date_naive();
    let old_date = current.start_on.to_string();
    let new_date = next.date.to_string();
    let mut edits = Vec::new();
    if current.title != next.title
    {
        edits.push(NewEvent::edit(
            TaskField::Title,
            Some(&current.title),
            Some(&next.title),
            today,
        ));
    }
    if current.note != next.note
    {
        edits.push(NewEvent::edit(
            TaskField::Note,
            current.note.as_deref(),
            next.note.as_deref(),
            today,
        ));
    }
    if current.kind != next.kind
    {
        edits.push(NewEvent::edit(
            TaskField::Kind,
            Some(kind_wire(current.kind)),
            Some(kind_wire(next.kind)),
            today,
        ));
    }
    if current.start_on != next.date
    {
        edits.push(NewEvent::edit(TaskField::Date, Some(&old_date), Some(&new_date), today));
    }

    if !edits.is_empty()
    {
        sqlx::query!(
            r#"
            UPDATE work_tasks SET kind = $3, title = $4, note = $5, start_on = $6, updated_ts = NOW()
            WHERE id = $1 AND user_id = $2
            "#,
            a_id,
            a_user.user_id,
            next.kind as TaskKind,
            next.title,
            next.note,
            next.date
        )
        .execute(&mut *tx)
        .await?;
        for edit in edits
        {
            append_event(&mut tx, a_id, edit).await?;
        }
    }

    let details = details(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(details))
}

pub async fn require_work_mark(a_conn: &mut PgConnection, a_user_id: Uuid, a_mark_id: Uuid) -> Result<(), ApiError>
{
    let is_work = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM status_marks WHERE id = $1 AND user_id = $2 AND status = 'work') AS "is_work!""#,
        a_mark_id,
        a_user_id
    )
    .fetch_one(&mut *a_conn)
    .await?;
    if !is_work
    {
        return Err(ApiError::Validation("status_mark_id"));
    }
    Ok(())
}

pub async fn log_task(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<TaskLogRequest>,
) -> Result<Json<WorkTaskDetailsDto>, ApiError>
{
    let report = clean_optional_text(a_req.report.as_deref(), MAX_REPORT_LEN, "report")?;
    let date = check_date(a_req.date)?;
    if date > Utc::now().date_naive() + Duration::days(MAX_FUTURE_LOG_DAYS)
    {
        return Err(ApiError::Validation("date"));
    }
    let mut tx = a_state.db.begin().await?;
    let task = lock_task(&mut tx, a_user.user_id, a_id).await?;
    if task.kind == TaskKind::General && date < task.start_on
    {
        return Err(ApiError::Validation("date"));
    }
    if let Some(mark_id) = a_req.status_mark_id
    {
        require_work_mark(&mut tx, a_user.user_id, mark_id).await?;
    }

    let kind = match a_req.action
    {
        TaskAction::Progress =>
        {
            if report.is_none()
            {
                return Err(ApiError::Validation("report"));
            }
            TaskEventKind::Progress
        }
        TaskAction::Done =>
        {
            if task.done_on.is_some()
            {
                return Err(ApiError::Conflict("TASK_DONE"));
            }
            sqlx::query!(
                "UPDATE work_tasks SET done_on = $2, done_ts = NOW(), updated_ts = NOW() WHERE id = $1",
                a_id,
                date
            )
            .execute(&mut *tx)
            .await?;
            TaskEventKind::Done
        }
        TaskAction::Reopen =>
        {
            if task.done_on.is_none()
            {
                return Err(ApiError::Conflict("TASK_OPEN"));
            }
            sqlx::query!(
                "UPDATE work_tasks SET done_on = NULL, done_ts = NULL, updated_ts = NOW() WHERE id = $1",
                a_id
            )
            .execute(&mut *tx)
            .await?;
            TaskEventKind::Reopened
        }
    };
    let event = NewEvent {
        report: report.as_deref(),
        status_mark_id: a_req.status_mark_id,
        ..NewEvent::plain(kind, date)
    };
    append_event(&mut tx, a_id, event).await?;

    let details = details(&mut tx, a_user.user_id, a_id).await?;
    tx.commit().await?;
    Ok(Json(details))
}

pub async fn archive_task(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_task(&mut tx, a_user.user_id, a_id).await?;
    append_event(
        &mut tx,
        a_id,
        NewEvent::plain(TaskEventKind::Deleted, Utc::now().date_naive()),
    )
    .await?;
    sqlx::query!(
        "UPDATE work_tasks SET deleted_ts = NOW(), updated_ts = NOW() WHERE id = $1",
        a_id
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn mark_work(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_mark_id: Uuid,
    a_date: NaiveDate,
) -> Result<MarkWorkDto, ApiError>
{
    let (general, day) = day_tasks(a_conn, a_user_id, a_date).await?;
    let logged = sqlx::query_as!(
        BlockLogDto,
        r#"
        SELECT e.task_id, t.title AS task_title, e.kind AS "kind: TaskEventKind", e.report, e.event_ts
        FROM work_task_events e
        JOIN work_tasks t ON t.id = e.task_id
        WHERE t.user_id = $1 AND e.status_mark_id = $2
        ORDER BY e.seq
        "#,
        a_user_id,
        a_mark_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(MarkWorkDto {
        date: a_date,
        general,
        day,
        logged,
    })
}
