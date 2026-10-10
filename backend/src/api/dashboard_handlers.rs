use std::collections::HashSet;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use shared_schema::{
    CreateWidgetRequest, DashboardDto, ReorderWidgetsRequest, SaveDashboardRequest, WidgetDto, WidgetKind,
};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::clean_name;
use crate::security::authz::require_member;
use crate::state::AppState;

const MAX_DASHBOARDS: i64 = 20;
const MAX_WIDGETS: i64 = 30;

struct WidgetRow
{
    id: Uuid,
    dashboard_id: Uuid,
    kind: WidgetKind,
    family_id: Option<Uuid>,
    family_name: Option<String>,
    is_available: bool,
}

pub async fn list_dashboards(
    State(a_state): State<AppState>,
    a_user: AuthUser,
) -> Result<Json<Vec<DashboardDto>>, ApiError>
{
    let mut conn = a_state.db.acquire().await?;
    load_dashboards(&mut conn, a_user.user_id, None).await.map(Json)
}

pub async fn create_dashboard(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<SaveDashboardRequest>,
) -> Result<(StatusCode, Json<DashboardDto>), ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    let mut tx = a_state.db.begin().await?;

    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM dashboards WHERE user_id = $1"#,
        a_user.user_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_DASHBOARDS
    {
        return Err(ApiError::Validation("dashboards"));
    }

    let id = sqlx::query_scalar!(
        "INSERT INTO dashboards (user_id, name, sort_ord) VALUES ($1, $2, $3) RETURNING id",
        a_user.user_id,
        name,
        count as i32
    )
    .fetch_one(&mut *tx)
    .await?;

    if a_req.is_prefilled
    {
        sqlx::query!(
            r#"
            INSERT INTO dash_widgets (dashboard_id, kind, family_id, sort_ord)
            SELECT $1, kind, family_id, ord
            FROM (
                SELECT 'my_status'::widget_kind_t AS kind, NULL::uuid AS family_id, 0 AS ord
                UNION ALL
                SELECT 'family_timeline', fm.family_id, 1 + ROW_NUMBER() OVER (ORDER BY fm.joined_ts)::int
                FROM family_mems fm WHERE fm.user_id = $2
                UNION ALL
                SELECT 'cashflow', NULL, 1000
            ) defaults
            "#,
            id,
            a_user.user_id
        )
        .execute(&mut *tx)
        .await?;
    }

    let dashboard = single(load_dashboards(&mut tx, a_user.user_id, Some(id)).await?)?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(dashboard)))
}

pub async fn rename_dashboard(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<SaveDashboardRequest>,
) -> Result<Json<DashboardDto>, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    let mut tx = a_state.db.begin().await?;

    let updated = sqlx::query!(
        "UPDATE dashboards SET name = $3 WHERE id = $1 AND user_id = $2",
        a_id,
        a_user.user_id,
        name
    )
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    let dashboard = single(load_dashboards(&mut tx, a_user.user_id, Some(a_id)).await?)?;
    tx.commit().await?;
    Ok(Json(dashboard))
}

pub async fn delete_dashboard(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        "DELETE FROM dashboards WHERE id = $1 AND user_id = $2",
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

pub async fn add_widget(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<CreateWidgetRequest>,
) -> Result<(StatusCode, Json<DashboardDto>), ApiError>
{
    let family_id = match (a_req.kind, a_req.family_id)
    {
        (WidgetKind::FamilyTimeline, Some(family_id)) =>
        {
            require_member(&a_state.db, family_id, a_user.user_id)
                .await
                .map_err(|_| ApiError::Validation("family_id"))?;
            Some(family_id)
        }
        (WidgetKind::FamilyTimeline, None) | (_, Some(_)) => return Err(ApiError::Validation("family_id")),
        (_, None) => None,
    };

    let mut tx = a_state.db.begin().await?;
    lock_dashboard(&mut tx, a_id, a_user.user_id).await?;

    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM dash_widgets WHERE dashboard_id = $1"#,
        a_id
    )
    .fetch_one(&mut *tx)
    .await?;
    if count >= MAX_WIDGETS
    {
        return Err(ApiError::Validation("widgets"));
    }

    sqlx::query!(
        r#"
        INSERT INTO dash_widgets (dashboard_id, kind, family_id, sort_ord)
        SELECT $1, $2, $3, COALESCE(MAX(sort_ord), 0) + 1 FROM dash_widgets WHERE dashboard_id = $1
        "#,
        a_id,
        a_req.kind as WidgetKind,
        family_id
    )
    .execute(&mut *tx)
    .await?;

    let dashboard = single(load_dashboards(&mut tx, a_user.user_id, Some(a_id)).await?)?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(dashboard)))
}

pub async fn delete_widget(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_id, a_widget_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<StatusCode, ApiError>
{
    let deleted = sqlx::query!(
        r#"
        DELETE FROM dash_widgets w
        USING dashboards d
        WHERE w.id = $1 AND w.dashboard_id = $2 AND d.id = w.dashboard_id AND d.user_id = $3
        "#,
        a_widget_id,
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

pub async fn reorder_widgets(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<ReorderWidgetsRequest>,
) -> Result<Json<DashboardDto>, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_dashboard(&mut tx, a_id, a_user.user_id).await?;

    let existing: HashSet<Uuid> = sqlx::query_scalar!("SELECT id FROM dash_widgets WHERE dashboard_id = $1", a_id)
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .collect();
    let requested: HashSet<Uuid> = a_req.widget_ids.iter().copied().collect();

    if requested.len() != a_req.widget_ids.len() || requested != existing
    {
        return Err(ApiError::Validation("widget_ids"));
    }

    sqlx::query!(
        r#"
        UPDATE dash_widgets w SET sort_ord = ordered.ord::int
        FROM UNNEST($2::uuid[]) WITH ORDINALITY AS ordered(id, ord)
        WHERE w.id = ordered.id AND w.dashboard_id = $1
        "#,
        a_id,
        &a_req.widget_ids
    )
    .execute(&mut *tx)
    .await?;

    let dashboard = single(load_dashboards(&mut tx, a_user.user_id, Some(a_id)).await?)?;
    tx.commit().await?;
    Ok(Json(dashboard))
}

async fn lock_dashboard(a_conn: &mut PgConnection, a_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query_scalar!(
        "SELECT id FROM dashboards WHERE id = $1 AND user_id = $2 FOR UPDATE",
        a_id,
        a_user_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;
    Ok(())
}

fn single(a_dashboards: Vec<DashboardDto>) -> Result<DashboardDto, ApiError>
{
    a_dashboards.into_iter().next().ok_or(ApiError::NotFound)
}

async fn load_dashboards(
    a_conn: &mut PgConnection,
    a_user_id: Uuid,
    a_only: Option<Uuid>,
) -> Result<Vec<DashboardDto>, ApiError>
{
    let dashboards = sqlx::query!(
        r#"
        SELECT id, name FROM dashboards
        WHERE user_id = $1 AND ($2::uuid IS NULL OR id = $2)
        ORDER BY sort_ord, created_ts
        "#,
        a_user_id,
        a_only
    )
    .fetch_all(&mut *a_conn)
    .await?;

    let ids: Vec<Uuid> = dashboards.iter().map(|dashboard| dashboard.id).collect();
    let widgets = sqlx::query_as!(
        WidgetRow,
        r#"
        SELECT
            w.id,
            w.dashboard_id,
            w.kind AS "kind: WidgetKind",
            w.family_id,
            f.name AS "family_name?",
            (w.family_id IS NULL OR fm.user_id IS NOT NULL) AS "is_available!"
        FROM dash_widgets w
        LEFT JOIN family_mems fm ON fm.family_id = w.family_id AND fm.user_id = $2
        LEFT JOIN families f ON f.id = w.family_id AND fm.user_id IS NOT NULL
        WHERE w.dashboard_id = ANY($1)
        ORDER BY w.sort_ord, w.created_ts
        "#,
        &ids,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(dashboards
        .into_iter()
        .map(|dashboard| DashboardDto {
            widgets: widgets
                .iter()
                .filter(|widget| widget.dashboard_id == dashboard.id)
                .map(|widget| WidgetDto {
                    id: widget.id,
                    kind: widget.kind,
                    family_id: widget.family_id,
                    family_name: widget.family_name.clone(),
                    is_available: widget.is_available,
                })
                .collect(),
            id: dashboard.id,
            name: dashboard.name,
        })
        .collect())
}
