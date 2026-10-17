use std::collections::HashSet;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{Duration, NaiveTime, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    ActivityLevel, BodyEntryDto, BodyMetric, BodySource, BodyValueDto, ChangePasswordRequest, CreateChildRequest,
    EntriesQuery, MetricPointDto, MetricValueDto, PersonRefDto, ProfileDto, SaveBodyEntryRequest, Sex,
    UpdateProfileRequest,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, ApiQuery, AuthUser};
use crate::api::user_handlers::age_on;
use crate::domain::errors::ApiError;
use crate::domain::validation::{check_birth_date, check_password, clean_name, clean_optional_text};
use crate::security::authz::require_admin;
use crate::security::profile_access::{profile_access, ProfileAccess};
use crate::security::rate_limit::LOGIN_PER_EMAIL;
use crate::state::AppState;

const MAX_ENTRY_NOTE_LEN: usize = 200;
const MAX_FUTURE_HOURS: i64 = 24;
const DEFAULT_ENTRIES_LIMIT: i64 = 100;
const MAX_ENTRIES_LIMIT: i64 = 500;
const MAX_HISTORY_POINTS: i64 = 3000;
const VALUE_SCALE: u32 = 2;
const MAX_GROUP_PEOPLE: i64 = 30;

pub async fn group_people(a_conn: &mut PgConnection, a_viewer_id: Uuid) -> Result<Vec<PersonRefDto>, ApiError>
{
    let people = sqlx::query_as!(
        PersonRefDto,
        r#"
        SELECT u.id, u.first_name, u.last_name, u.id = $1 AS "is_me!", u.is_managed,
               can_manage_person($1, u.id) AS "can_edit!"
        FROM users u
        WHERE u.id = $1
           OR u.id IN (
               SELECT theirs.user_id
               FROM family_mems mine
               JOIN family_mems theirs ON theirs.family_id = mine.family_id
               WHERE mine.user_id = $1
           )
        ORDER BY (u.id = $1) DESC, u.is_managed, u.first_name, u.last_name, u.id
        LIMIT $2
        "#,
        a_viewer_id,
        MAX_GROUP_PEOPLE
    )
    .fetch_all(a_conn)
    .await?;
    Ok(people)
}

pub async fn list_people(State(a_state): State<AppState>, a_user: AuthUser)
    -> Result<Json<Vec<PersonRefDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    Ok(Json(group_people(&mut conn, a_user.user_id).await?))
}

struct PersonRow
{
    first_name: String,
    last_name: String,
    email: Option<String>,
    birth_date: chrono::NaiveDate,
    sex: Option<Sex>,
    activity: Option<ActivityLevel>,
}

struct EntryRow
{
    id: Uuid,
    measured_ts: chrono::DateTime<Utc>,
    source: BodySource,
    note: Option<String>,
}

struct ValueRow
{
    entry_id: Uuid,
    metric: BodyMetric,
    value: Decimal,
}

pub async fn get_person(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_person_id): ApiPath<Uuid>,
) -> Result<Json<ProfileDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    let access = profile_access(&mut conn, a_user.user_id, a_person_id).await?;
    person_dto(&mut conn, a_person_id, &access).await.map(Json)
}

pub async fn update_person(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_person_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<UpdateProfileRequest>,
) -> Result<Json<ProfileDto>, ApiError>
{
    let first_name = clean_name(&a_req.first_name, "first_name")?;
    let last_name = clean_name(&a_req.last_name, "last_name")?;
    check_birth_date(a_req.birth_date)?;

    let mut conn = a_state.db.acquire().await?;
    let access = profile_access(&mut conn, a_user.user_id, a_person_id).await?;
    access.require_manager()?;

    sqlx::query!(
        r#"
        UPDATE users SET first_name = $2, last_name = $3, birth_date = $4, sex = $5, activity = $6
        WHERE id = $1
        "#,
        a_person_id,
        first_name,
        last_name,
        a_req.birth_date,
        a_req.sex as Option<Sex>,
        a_req.activity as Option<ActivityLevel>
    )
    .execute(&mut *conn)
    .await?;

    person_dto(&mut conn, a_person_id, &access).await.map(Json)
}

pub async fn change_password(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<ChangePasswordRequest>,
) -> Result<StatusCode, ApiError>
{
    check_password(&a_req.new_password)?;
    a_state
        .limiter
        .hit(&format!("password-change:{}", a_user.user_id), &LOGIN_PER_EMAIL)?;

    let row = sqlx::query!(
        r#"SELECT password_hash AS "password_hash!", is_pwd_peppered FROM users WHERE id = $1 AND NOT is_managed"#,
        a_user.user_id
    )
    .fetch_optional(&a_state.db)
    .await?
    .ok_or(ApiError::NotFound)?;

    let is_valid = a_state
        .passwords
        .verify(a_req.current_password, row.password_hash, row.is_pwd_peppered)
        .await?;
    if !is_valid
    {
        return Err(ApiError::Conflict("WRONG_PASSWORD"));
    }

    let password_hash = a_state.passwords.hash(a_req.new_password).await?;
    let mut tx = a_state.db.begin().await?;
    sqlx::query!(
        "UPDATE users SET password_hash = $2, is_pwd_peppered = TRUE WHERE id = $1",
        a_user.user_id,
        password_hash
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "DELETE FROM sessions WHERE user_id = $1 AND id <> $2",
        a_user.user_id,
        a_user.session_id
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn list_entries(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_person_id): ApiPath<Uuid>,
    ApiQuery(a_query): ApiQuery<EntriesQuery>,
) -> Result<Json<Vec<BodyEntryDto>>, ApiError>
{
    let limit = a_query
        .limit
        .unwrap_or(DEFAULT_ENTRIES_LIMIT)
        .clamp(1, MAX_ENTRIES_LIMIT);

    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_person_id).await?;

    let entries = sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, measured_ts, source AS "source: BodySource", note
        FROM body_entries
        WHERE user_id = $1 AND ($2::TIMESTAMPTZ IS NULL OR measured_ts < $2)
        ORDER BY measured_ts DESC
        LIMIT $3
        "#,
        a_person_id,
        a_query.before,
        limit
    )
    .fetch_all(&mut *conn)
    .await?;

    let ids: Vec<Uuid> = entries.iter().map(|entry| entry.id).collect();
    let values = load_values(&mut conn, &ids).await?;

    Ok(Json(
        entries
            .into_iter()
            .map(|entry| entry_dto(entry, &values))
            .filter(|entry| !entry.values.is_empty())
            .collect(),
    ))
}

pub async fn get_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_person_id, a_entry_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<Json<BodyEntryDto>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_person_id).await?;
    let entry = load_entry(&mut conn, a_person_id, a_entry_id).await?;
    let values = load_values(&mut conn, &[a_entry_id]).await?;

    let dto = entry_dto(entry, &values);
    if dto.values.is_empty()
    {
        return Err(ApiError::NotFound);
    }
    Ok(Json(dto))
}

pub async fn create_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_person_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveBodyEntryRequest>,
) -> Result<(StatusCode, Json<BodyEntryDto>), ApiError>
{
    let values = clean_values(&a_req.values)?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_ENTRY_NOTE_LEN, "note")?;

    let mut tx = a_state.db.begin().await?;
    profile_access(&mut tx, a_user.user_id, a_person_id)
        .await?
        .require_manager()?;
    check_measured_ts(&mut tx, a_person_id, a_req.measured_ts).await?;

    let entry_id = sqlx::query_scalar!(
        r#"
        INSERT INTO body_entries (user_id, measured_ts, note, created_by)
        VALUES ($1, $2, $3, $4)
        RETURNING id
        "#,
        a_person_id,
        a_req.measured_ts,
        note,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    insert_values(&mut tx, entry_id, &values).await?;

    let entry = load_entry(&mut tx, a_person_id, entry_id).await?;
    let rows = load_values(&mut tx, &[entry_id]).await?;
    tx.commit().await?;

    Ok((StatusCode::CREATED, Json(entry_dto(entry, &rows))))
}

pub async fn update_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_person_id, a_entry_id)): ApiPath<(Uuid, Uuid)>,
    ApiJson(a_req): ApiJson<SaveBodyEntryRequest>,
) -> Result<Json<BodyEntryDto>, ApiError>
{
    let values = clean_values(&a_req.values)?;
    let note = clean_optional_text(a_req.note.as_deref(), MAX_ENTRY_NOTE_LEN, "note")?;

    let mut tx = a_state.db.begin().await?;
    profile_access(&mut tx, a_user.user_id, a_person_id)
        .await?
        .require_manager()?;
    check_measured_ts(&mut tx, a_person_id, a_req.measured_ts).await?;

    let updated = sqlx::query!(
        "UPDATE body_entries SET measured_ts = $3, note = $4 WHERE id = $1 AND user_id = $2",
        a_entry_id,
        a_person_id,
        a_req.measured_ts,
        note
    )
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    sqlx::query!("DELETE FROM body_values WHERE entry_id = $1", a_entry_id)
        .execute(&mut *tx)
        .await?;
    insert_values(&mut tx, a_entry_id, &values).await?;

    let entry = load_entry(&mut tx, a_person_id, a_entry_id).await?;
    let rows = load_values(&mut tx, &[a_entry_id]).await?;
    tx.commit().await?;

    Ok(Json(entry_dto(entry, &rows)))
}

pub async fn delete_entry(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_person_id, a_entry_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<StatusCode, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_person_id)
        .await?
        .require_manager()?;

    let deleted = sqlx::query!(
        "DELETE FROM body_entries WHERE id = $1 AND user_id = $2",
        a_entry_id,
        a_person_id
    )
    .execute(&mut *conn)
    .await?;
    if deleted.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    Ok(StatusCode::NO_CONTENT)
}

pub async fn metric_history(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_person_id, a_metric)): ApiPath<(Uuid, BodyMetric)>,
) -> Result<Json<Vec<MetricPointDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    profile_access(&mut conn, a_user.user_id, a_person_id).await?;

    let points = sqlx::query_as!(
        MetricPointDto,
        r#"
        SELECT entry_id, measured_ts, value
        FROM (
            SELECT e.id AS entry_id, e.measured_ts, v.value
            FROM body_values v
            JOIN body_entries e ON e.id = v.entry_id
            WHERE e.user_id = $1 AND v.metric = $2
            ORDER BY e.measured_ts DESC
            LIMIT $3
        ) recent
        ORDER BY measured_ts
        "#,
        a_person_id,
        a_metric as BodyMetric,
        MAX_HISTORY_POINTS
    )
    .fetch_all(&mut *conn)
    .await?;

    Ok(Json(points))
}

pub async fn create_child(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_family_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<CreateChildRequest>,
) -> Result<(StatusCode, Json<ProfileDto>), ApiError>
{
    let first_name = clean_name(&a_req.first_name, "first_name")?;
    let last_name = clean_name(&a_req.last_name, "last_name")?;
    check_birth_date(a_req.birth_date)?;

    let mut tx = a_state.db.begin().await?;
    crate::security::authz::lock_family(&mut tx, a_family_id).await?;
    require_admin(&mut *tx, a_family_id, a_user.user_id).await?;

    let child_id = sqlx::query_scalar!(
        r#"
        INSERT INTO users (first_name, last_name, birth_date, sex, is_managed, managed_by)
        VALUES ($1, $2, $3, $4, TRUE, $5)
        RETURNING id
        "#,
        first_name,
        last_name,
        a_req.birth_date,
        a_req.sex as Sex,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;

    sqlx::query!(
        "INSERT INTO family_mems (family_id, user_id, role) VALUES ($1, $2, 'standard')",
        a_family_id,
        child_id
    )
    .execute(&mut *tx)
    .await?;

    let access = profile_access(&mut tx, a_user.user_id, child_id).await?;
    let dto = person_dto(&mut tx, child_id, &access).await?;
    tx.commit().await?;

    Ok((StatusCode::CREATED, Json(dto)))
}

pub async fn delete_orphan_children(a_conn: &mut PgConnection) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        DELETE FROM users u
        WHERE u.is_managed AND NOT EXISTS (SELECT 1 FROM family_mems fm WHERE fm.user_id = u.id)
        "#
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

async fn person_dto(
    a_conn: &mut PgConnection,
    a_person_id: Uuid,
    a_access: &ProfileAccess,
) -> Result<ProfileDto, ApiError>
{
    let person = sqlx::query_as!(
        PersonRow,
        r#"
        SELECT first_name, last_name, email, birth_date, sex AS "sex: Sex", activity AS "activity: ActivityLevel"
        FROM users WHERE id = $1
        "#,
        a_person_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    let latest = sqlx::query_as!(
        MetricValueDto,
        r#"
        SELECT metric AS "metric!: BodyMetric", value AS "value!", measured_ts AS "measured_ts!", prev_value, prev_ts
        FROM (
            SELECT v.metric, v.value, e.measured_ts,
                   LEAD(v.value) OVER recent AS prev_value,
                   LEAD(e.measured_ts) OVER recent AS prev_ts,
                   ROW_NUMBER() OVER recent AS position
            FROM body_values v
            JOIN body_entries e ON e.id = v.entry_id
            WHERE e.user_id = $1
            WINDOW recent AS (PARTITION BY v.metric ORDER BY e.measured_ts DESC, e.created_ts DESC)
        ) ranked
        WHERE position = 1
        ORDER BY metric
        "#,
        a_person_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(ProfileDto {
        id: a_person_id,
        first_name: person.first_name,
        last_name: person.last_name,
        email: person.email.filter(|_| a_access.is_self),
        birth_date: a_access.is_manager.then_some(person.birth_date),
        age: Some(age_on(person.birth_date, Utc::now().date_naive())),
        sex: person.sex,
        activity: person.activity.filter(|_| a_access.is_manager),
        is_self: a_access.is_self,
        is_managed: a_access.is_managed,
        can_edit: a_access.is_manager,
        latest,
    })
}

async fn load_entry(a_conn: &mut PgConnection, a_person_id: Uuid, a_entry_id: Uuid) -> Result<EntryRow, ApiError>
{
    sqlx::query_as!(
        EntryRow,
        r#"
        SELECT id, measured_ts, source AS "source: BodySource", note
        FROM body_entries WHERE id = $1 AND user_id = $2
        "#,
        a_entry_id,
        a_person_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)
}

async fn load_values(a_conn: &mut PgConnection, a_entry_ids: &[Uuid]) -> Result<Vec<ValueRow>, ApiError>
{
    Ok(sqlx::query_as!(
        ValueRow,
        r#"
        SELECT entry_id, metric AS "metric: BodyMetric", value
        FROM body_values WHERE entry_id = ANY($1)
        ORDER BY entry_id, metric
        "#,
        a_entry_ids
    )
    .fetch_all(&mut *a_conn)
    .await?)
}

async fn insert_values(a_conn: &mut PgConnection, a_entry_id: Uuid, a_values: &[BodyValueDto]) -> Result<(), ApiError>
{
    let metrics: Vec<BodyMetric> = a_values.iter().map(|value| value.metric).collect();
    let amounts: Vec<Decimal> = a_values.iter().map(|value| value.value).collect();
    sqlx::query!(
        r#"
        INSERT INTO body_values (entry_id, metric, value)
        SELECT $1, metric, value FROM UNNEST($2::body_metric_t[], $3::NUMERIC[]) AS input(metric, value)
        "#,
        a_entry_id,
        metrics as Vec<BodyMetric>,
        &amounts
    )
    .execute(&mut *a_conn)
    .await?;
    Ok(())
}

async fn check_measured_ts(
    a_conn: &mut PgConnection,
    a_person_id: Uuid,
    a_ts: chrono::DateTime<Utc>,
) -> Result<(), ApiError>
{
    let birth_date = sqlx::query_scalar!("SELECT birth_date FROM users WHERE id = $1", a_person_id)
        .fetch_one(&mut *a_conn)
        .await?;
    let earliest = (birth_date - Duration::days(1)).and_time(NaiveTime::MIN).and_utc();
    let latest = Utc::now() + Duration::hours(MAX_FUTURE_HOURS);

    if a_ts < earliest || a_ts > latest
    {
        return Err(ApiError::Validation("measured_ts"));
    }
    Ok(())
}

fn clean_values(a_values: &[BodyValueDto]) -> Result<Vec<BodyValueDto>, ApiError>
{
    let mut seen = HashSet::new();
    if a_values.is_empty()
    {
        return Err(ApiError::Validation("values"));
    }

    a_values
        .iter()
        .map(|input| {
            let value = input.value.round_dp(VALUE_SCALE);
            let (min, max) = input.metric.range();
            if !seen.insert(input.metric) || value < min || value > max
            {
                return Err(ApiError::Validation("values"));
            }
            Ok(BodyValueDto {
                metric: input.metric,
                value,
            })
        })
        .collect()
}

fn entry_dto(a_entry: EntryRow, a_values: &[ValueRow]) -> BodyEntryDto
{
    BodyEntryDto {
        id: a_entry.id,
        measured_ts: a_entry.measured_ts,
        source: a_entry.source,
        note: a_entry.note,
        values: a_values
            .iter()
            .filter(|row| row.entry_id == a_entry.id)
            .map(|row| BodyValueDto {
                metric: row.metric,
                value: row.value,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn value(a_metric: BodyMetric, a_value: &str) -> BodyValueDto
    {
        BodyValueDto {
            metric: a_metric,
            value: a_value.parse().unwrap(),
        }
    }

    #[test]
    fn values_are_rounded_and_checked_against_metric_ranges()
    {
        let cleaned = clean_values(&[value(BodyMetric::Weight, "72.456"), value(BodyMetric::Waist, "81")]).unwrap();
        assert_eq!(cleaned[0].value.to_string(), "72.46");

        assert!(clean_values(&[]).is_err());
        assert!(clean_values(&[value(BodyMetric::Weight, "0.5")]).is_err());
        assert!(clean_values(&[value(BodyMetric::BodyFat, "80")]).is_err());
        assert!(clean_values(&[value(BodyMetric::BoneMass, "0.1")]).is_err());
        assert!(clean_values(&[value(BodyMetric::BoneMass, "0.3")]).is_ok());
        assert!(clean_values(&[value(BodyMetric::Weight, "70"), value(BodyMetric::Weight, "71")]).is_err());
        assert!(clean_values(&[value(BodyMetric::Height, "52")]).is_ok());
    }
}
