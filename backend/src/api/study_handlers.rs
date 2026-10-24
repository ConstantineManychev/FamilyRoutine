use std::collections::HashMap;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    MarkStudyDto, SaveNoteRequest, SaveTopicRequest, StudyNoteDto, StudyNotesQuery, StudyProgressDto, StudyTopicDto,
    StudyTreeDto, StudyUnit,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_optional_text, clean_text};
use crate::services::study::{aggregate, TopicGoal};
use crate::services::tree::{Forest, TreeError};
use crate::state::AppState;

const MAX_TITLE_LEN: usize = 200;
const MAX_DESCRIPTION_LEN: usize = 2000;
const MAX_NOTE_LEN: usize = 5000;
const MAX_TOPICS_PER_USER: i64 = 1000;
const MAX_NOTES_PER_USER: i64 = 20_000;
const MAX_NOTES_SHOWN: i64 = 500;
const MAX_GOAL: i64 = 100_000;
const PERCENT_TARGET: i64 = 100;
const GOAL_SCALE: u32 = 1;
const MAX_NOTE_PAST_DAYS: i64 = 3660;
const MAX_NOTE_FUTURE_DAYS: i64 = 1;

struct TopicRow
{
    id: Uuid,
    parent_id: Option<Uuid>,
    title: String,
    description: Option<String>,
    unit: StudyUnit,
    target: Decimal,
    done: Decimal,
    updated_ts: DateTime<Utc>,
    note_count: i64,
}

struct NoteRow
{
    id: Uuid,
    topic_id: Uuid,
    body: String,
    note_ts: DateTime<Utc>,
    created_ts: DateTime<Utc>,
    updated_ts: DateTime<Utc>,
}

struct StudyTree
{
    rows: Vec<TopicRow>,
    forest: Forest,
    progress: HashMap<Uuid, StudyProgressDto>,
}

impl StudyTree
{
    fn row(&self, a_id: Uuid) -> Result<&TopicRow, ApiError>
    {
        self.rows.iter().find(|row| row.id == a_id).ok_or(ApiError::NotFound)
    }

    fn dto(&self, a_row: &TopicRow) -> StudyTopicDto
    {
        StudyTopicDto {
            id: a_row.id,
            parent_id: a_row.parent_id,
            title: a_row.title.clone(),
            description: a_row.description.clone(),
            unit: a_row.unit,
            target: a_row.target.normalize(),
            done: a_row.done.normalize(),
            depth: self.forest.depth(a_row.id),
            child_count: self.forest.children(a_row.id).len(),
            note_count: a_row.note_count,
            progress: self.progress.get(&a_row.id).cloned().unwrap_or(StudyProgressDto {
                percent: Decimal::ZERO,
                done: None,
                target: None,
                unit: None,
                is_aggregated: false,
            }),
            updated_ts: a_row.updated_ts,
        }
    }

    fn path(&self, a_id: Uuid) -> Vec<String>
    {
        let mut ids = self.forest.ancestors(a_id);
        ids.reverse();
        ids.push(a_id);
        ids.into_iter()
            .filter_map(|id| self.rows.iter().find(|row| row.id == id))
            .map(|row| row.title.clone())
            .collect()
    }

    fn note(&self, a_row: NoteRow) -> StudyNoteDto
    {
        StudyNoteDto {
            topic_path: self.path(a_row.topic_id),
            id: a_row.id,
            topic_id: a_row.topic_id,
            body: a_row.body,
            note_ts: a_row.note_ts,
            created_ts: a_row.created_ts,
            updated_ts: a_row.updated_ts,
        }
    }
}

struct CleanTopic
{
    parent_id: Option<Uuid>,
    title: String,
    description: Option<String>,
    unit: StudyUnit,
    target: Decimal,
    done: Decimal,
}

fn tree_error(a_error: TreeError) -> ApiError
{
    match a_error
    {
        TreeError::UnknownNode => ApiError::Validation("parent_id"),
        TreeError::Cycle => ApiError::Conflict("TOPIC_CYCLE"),
        TreeError::TooDeep => ApiError::Conflict("TOPIC_TOO_DEEP"),
    }
}

pub fn clean_goal(a_unit: StudyUnit, a_target: Decimal, a_done: Decimal) -> Result<(Decimal, Decimal), ApiError>
{
    let target = if a_unit == StudyUnit::Percent
    {
        Decimal::from(PERCENT_TARGET)
    }
    else
    {
        a_target.round_dp(GOAL_SCALE)
    };
    let done = a_done.round_dp(GOAL_SCALE);
    if target <= Decimal::ZERO || target > Decimal::from(MAX_GOAL)
    {
        return Err(ApiError::Validation("target"));
    }
    let max_done = if a_unit == StudyUnit::Percent
    {
        target
    }
    else
    {
        Decimal::from(MAX_GOAL)
    };
    if done < Decimal::ZERO || done > max_done
    {
        return Err(ApiError::Validation("done"));
    }
    Ok((target.normalize(), done.normalize()))
}

fn clean_topic(a_req: SaveTopicRequest) -> Result<CleanTopic, ApiError>
{
    let (target, done) = clean_goal(a_req.unit, a_req.target, a_req.done)?;
    Ok(CleanTopic {
        parent_id: a_req.parent_id,
        title: clean_text(&a_req.title, 1, MAX_TITLE_LEN, "title")?,
        description: clean_optional_text(a_req.description.as_deref(), MAX_DESCRIPTION_LEN, "description")?,
        unit: a_req.unit,
        target,
        done,
    })
}

fn check_note_ts(a_ts: Option<DateTime<Utc>>) -> Result<DateTime<Utc>, ApiError>
{
    let now = Utc::now();
    let ts = a_ts.unwrap_or(now);
    if ts < now - Duration::days(MAX_NOTE_PAST_DAYS) || ts > now + Duration::days(MAX_NOTE_FUTURE_DAYS)
    {
        return Err(ApiError::Validation("note_ts"));
    }
    Ok(ts)
}

async fn lock_topics(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        "SELECT pg_advisory_xact_lock(hashtext($1::text))",
        format!("study:{a_user_id}")
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

async fn load_tree(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<StudyTree, ApiError>
{
    let rows = sqlx::query_as!(
        TopicRow,
        r#"
        SELECT t.id, t.parent_id, t.title, t.description, t.unit AS "unit: StudyUnit", t.target, t.done, t.updated_ts,
               (SELECT COUNT(*) FROM study_notes n WHERE n.topic_id = t.id) AS "note_count!"
        FROM study_topics t
        WHERE t.user_id = $1
        ORDER BY t.created_ts, t.id
        "#,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;
    let forest = Forest::new(rows.iter().map(|row| (row.id, row.parent_id)));
    let goals: HashMap<Uuid, TopicGoal> = rows
        .iter()
        .map(|row| {
            (
                row.id,
                TopicGoal {
                    unit: row.unit,
                    target: row.target,
                    done: row.done,
                },
            )
        })
        .collect();
    let progress = aggregate(&forest, &goals);
    Ok(StudyTree { rows, forest, progress })
}

pub async fn list_topics(State(a_state): State<AppState>, a_user: AuthUser) -> Result<Json<StudyTreeDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let tree = load_tree(&mut conn, a_user.user_id).await?;
    Ok(Json(StudyTreeDto {
        max_depth: a_state.cfg.study_max_depth,
        topics: tree.rows.iter().map(|row| tree.dto(row)).collect(),
    }))
}

pub async fn create_topic(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveTopicRequest>,
) -> Result<(StatusCode, Json<StudyTopicDto>), ApiError>
{
    let topic = clean_topic(a_req)?;
    let mut tx = a_state.db.begin().await?;
    lock_topics(&mut tx, a_user.user_id).await?;
    let tree = load_tree(&mut tx, a_user.user_id).await?;
    tree.forest
        .check_add(topic.parent_id, a_state.cfg.study_max_depth)
        .map_err(tree_error)?;
    if i64::try_from(tree.rows.len()).unwrap_or(i64::MAX) >= MAX_TOPICS_PER_USER
    {
        return Err(ApiError::Conflict("TOO_MANY_TOPICS"));
    }

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO study_topics (user_id, parent_id, title, description, unit, target, done)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id
        "#,
        a_user.user_id,
        topic.parent_id,
        topic.title,
        topic.description,
        topic.unit as StudyUnit,
        topic.target,
        topic.done
    )
    .fetch_one(&mut *tx)
    .await?;

    let tree = load_tree(&mut tx, a_user.user_id).await?;
    let created = tree.dto(tree.row(id)?);
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn update_topic(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveTopicRequest>,
) -> Result<Json<StudyTopicDto>, ApiError>
{
    let topic = clean_topic(a_req)?;
    let mut tx = a_state.db.begin().await?;
    lock_topics(&mut tx, a_user.user_id).await?;
    let tree = load_tree(&mut tx, a_user.user_id).await?;
    tree.row(a_id)?;
    tree.forest
        .check_move(a_id, topic.parent_id, a_state.cfg.study_max_depth)
        .map_err(tree_error)?;

    sqlx::query!(
        r#"
        UPDATE study_topics
        SET parent_id = $3, title = $4, description = $5, unit = $6, target = $7, done = $8, updated_ts = NOW()
        WHERE id = $1 AND user_id = $2
        "#,
        a_id,
        a_user.user_id,
        topic.parent_id,
        topic.title,
        topic.description,
        topic.unit as StudyUnit,
        topic.target,
        topic.done
    )
    .execute(&mut *tx)
    .await?;

    let tree = load_tree(&mut tx, a_user.user_id).await?;
    let updated = tree.dto(tree.row(a_id)?);
    tx.commit().await?;
    Ok(Json(updated))
}

pub async fn delete_topic(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_topics(&mut tx, a_user.user_id).await?;
    let tree = load_tree(&mut tx, a_user.user_id).await?;
    tree.row(a_id)?;
    if !tree.forest.children(a_id).is_empty()
    {
        return Err(ApiError::Conflict("TOPIC_HAS_CHILDREN"));
    }
    sqlx::query!(
        "DELETE FROM study_topics WHERE id = $1 AND user_id = $2",
        a_id,
        a_user.user_id
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn list_notes(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<StudyNotesQuery>,
) -> Result<Json<Vec<StudyNoteDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let tree = load_tree(&mut conn, a_user.user_id).await?;
    tree.row(a_id)?;
    let topic_ids = if a_query.is_branch
    {
        tree.forest.subtree(a_id)
    }
    else
    {
        vec![a_id]
    };
    let rows = sqlx::query_as!(
        NoteRow,
        r#"
        SELECT id, topic_id, body, note_ts, created_ts, updated_ts
        FROM study_notes
        WHERE user_id = $1 AND topic_id = ANY($2)
        ORDER BY note_ts DESC, created_ts DESC
        LIMIT $3
        "#,
        a_user.user_id,
        &topic_ids,
        MAX_NOTES_SHOWN
    )
    .fetch_all(&mut *conn)
    .await?;
    Ok(Json(rows.into_iter().map(|row| tree.note(row)).collect()))
}

async fn note_dto(a_conn: &mut PgConnection, a_user_id: Uuid, a_id: Uuid) -> Result<StudyNoteDto, ApiError>
{
    let row = sqlx::query_as!(
        NoteRow,
        "SELECT id, topic_id, body, note_ts, created_ts, updated_ts FROM study_notes WHERE id = $1 AND user_id = $2",
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;
    let tree = load_tree(a_conn, a_user_id).await?;
    Ok(tree.note(row))
}

pub async fn create_note(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_topic_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveNoteRequest>,
) -> Result<(StatusCode, Json<StudyNoteDto>), ApiError>
{
    let body = clean_text(&a_req.body, 1, MAX_NOTE_LEN, "body")?;
    let note_ts = check_note_ts(a_req.note_ts)?;
    let mut tx = a_state.db.begin().await?;
    lock_topics(&mut tx, a_user.user_id).await?;
    let is_own = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM study_topics WHERE id = $1 AND user_id = $2) AS "is_own!""#,
        a_topic_id,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if !is_own
    {
        return Err(ApiError::NotFound);
    }
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM study_notes WHERE user_id = $1"#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_NOTES_PER_USER
    {
        return Err(ApiError::Conflict("TOO_MANY_NOTES"));
    }
    let id = sqlx::query_scalar!(
        "INSERT INTO study_notes (topic_id, user_id, body, note_ts) VALUES ($1, $2, $3, $4) RETURNING id",
        a_topic_id,
        a_user.user_id,
        body,
        note_ts
    )
    .fetch_one(&mut *tx)
    .await?;
    let note = note_dto(&mut tx, a_user.user_id, id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(note)))
}

pub async fn update_note(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveNoteRequest>,
) -> Result<Json<StudyNoteDto>, ApiError>
{
    let body = clean_text(&a_req.body, 1, MAX_NOTE_LEN, "body")?;
    let note_ts = check_note_ts(a_req.note_ts)?;
    let mut conn = a_state.db.acquire().await?;
    let updated = sqlx::query!(
        "UPDATE study_notes SET body = $3, note_ts = $4, updated_ts = NOW() WHERE id = $1 AND user_id = $2",
        a_id,
        a_user.user_id,
        body,
        note_ts
    )
    .execute(&mut *conn)
    .await?;
    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }
    note_dto(&mut conn, a_user.user_id, a_id).await.map(Json)
}

pub async fn delete_note(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM study_notes WHERE id = $1 AND user_id = $2",
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

pub async fn mark_study(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_start: DateTime<Utc>,
    a_end: Option<DateTime<Utc>>,
) -> Result<MarkStudyDto, ApiError>
{
    let tree = load_tree(a_conn, a_user_id).await?;
    let rows = sqlx::query_as!(
        NoteRow,
        r#"
        SELECT id, topic_id, body, note_ts, created_ts, updated_ts
        FROM study_notes
        WHERE user_id = $1 AND note_ts >= $2 AND note_ts <= COALESCE($3, NOW())
        ORDER BY note_ts
        LIMIT $4
        "#,
        a_user_id,
        a_start,
        a_end,
        MAX_NOTES_SHOWN
    )
    .fetch_all(&mut *a_conn)
    .await?;
    Ok(MarkStudyDto {
        topics: tree
            .rows
            .iter()
            .filter(|row| row.parent_id.is_none())
            .map(|row| tree.dto(row))
            .collect(),
        notes: rows.into_iter().map(|row| tree.note(row)).collect(),
    })
}
