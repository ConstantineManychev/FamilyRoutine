use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{Duration, Utc};
use shared_schema::{
    AcceptInviteRequest, AcceptInviteResponse, CreateFamilyRequest, CreateInviteRequest, CreatedInviteDto,
    FamDetailDto, FamInviteDto, FamListItemDto, FamMemberDto, MemberRole, RenameFamilyRequest,
    TransferOwnershipRequest, UpdateMemberRoleRequest,
};
use sqlx::{PgConnection, PgPool};
use uuid::Uuid;

use crate::api::extract::{ApiJson, ApiPath, AuthUser, ClientIp};
use crate::domain::errors::ApiError;
use crate::domain::validation::{clean_name, clean_optional_text, MAX_NAME_LEN};
use crate::security::authz::{lock_family, member_access, require_admin, require_member, require_owner, FamAccess};
use crate::security::invite_code;
use crate::security::rate_limit::{INVITE_ACCEPT_PER_IP, INVITE_ACCEPT_PER_USER, INVITE_CREATE_PER_USER};
use crate::state::AppState;

const INVITE_TTL_DAYS: i64 = 7;
const MAX_ACTIVE_INVITES: i64 = 20;

pub async fn list_families(
    State(a_state): State<AppState>,
    a_user: AuthUser,
) -> Result<Json<Vec<FamListItemDto>>, ApiError>
{
    let fams = sqlx::query_as!(
        FamListItemDto,
        r#"
        SELECT
            f.id,
            f.name,
            fm.role AS "role: MemberRole",
            (f.owner_id = fm.user_id) AS "is_owner!",
            (SELECT COUNT(*) FROM family_mems m WHERE m.family_id = f.id) AS "member_count!"
        FROM families f
        JOIN family_mems fm ON fm.family_id = f.id
        WHERE fm.user_id = $1
        ORDER BY f.name
        "#,
        a_user.user_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(fams))
}

pub async fn create_family(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiJson(a_req): ApiJson<CreateFamilyRequest>,
) -> Result<(StatusCode, Json<FamDetailDto>), ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    let fam_id = Uuid::new_v4();

    let mut tx = a_state.db.begin().await?;

    sqlx::query!(
        "INSERT INTO families (id, name, owner_id) VALUES ($1, $2, $3)",
        fam_id,
        name,
        a_user.user_id
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "INSERT INTO family_mems (family_id, user_id, role) VALUES ($1, $2, 'admin')",
        fam_id,
        a_user.user_id
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    let owner_access = FamAccess {
        role: MemberRole::Admin,
        is_owner: true,
        is_routine_shared: true,
    };

    let detail = load_family_detail(&a_state.db, fam_id, owner_access).await?;
    Ok((StatusCode::CREATED, Json(detail)))
}

pub async fn get_family(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
) -> Result<Json<FamDetailDto>, ApiError>
{
    let access = require_member(&a_state.db, a_fam_id, a_user.user_id).await?;
    Ok(Json(load_family_detail(&a_state.db, a_fam_id, access).await?))
}

pub async fn rename_family(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<RenameFamilyRequest>,
) -> Result<StatusCode, ApiError>
{
    let name = clean_name(&a_req.name, "name")?;
    require_admin(&a_state.db, a_fam_id, a_user.user_id).await?;

    sqlx::query!("UPDATE families SET name = $2 WHERE id = $1", a_fam_id, name)
        .execute(&a_state.db)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete_family(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_family(&mut tx, a_fam_id).await?;
    require_owner(&mut *tx, a_fam_id, a_user.user_id).await?;

    sqlx::query!("DELETE FROM families WHERE id = $1", a_fam_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn leave_family(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_family(&mut tx, a_fam_id).await?;
    let access = require_member(&mut *tx, a_fam_id, a_user.user_id).await?;

    if access.is_owner
    {
        let member_count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "count!" FROM family_mems WHERE family_id = $1"#,
            a_fam_id
        )
        .fetch_one(&mut *tx)
        .await?;

        if member_count > 1
        {
            return Err(ApiError::Conflict("OWNER_MUST_TRANSFER"));
        }

        sqlx::query!("DELETE FROM families WHERE id = $1", a_fam_id)
            .execute(&mut *tx)
            .await?;
    }
    else
    {
        drop_membership(&mut tx, a_fam_id, a_user.user_id).await?;
    }

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn update_member_role(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_fam_id, a_target_id)): ApiPath<(Uuid, Uuid)>,
    ApiJson(a_req): ApiJson<UpdateMemberRoleRequest>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_family(&mut tx, a_fam_id).await?;
    require_owner(&mut *tx, a_fam_id, a_user.user_id).await?;

    let target = require_member(&mut *tx, a_fam_id, a_target_id).await?;

    if target.is_owner
    {
        return Err(ApiError::Conflict("OWNER_PROTECTED"));
    }

    sqlx::query!(
        "UPDATE family_mems SET role = $3 WHERE family_id = $1 AND user_id = $2",
        a_fam_id,
        a_target_id,
        a_req.role as MemberRole
    )
    .execute(&mut *tx)
    .await?;

    if a_req.role == MemberRole::Standard
    {
        revoke_invites_by(&mut tx, a_fam_id, a_target_id).await?;
    }

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn remove_member(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_fam_id, a_target_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_family(&mut tx, a_fam_id).await?;
    let actor = require_admin(&mut *tx, a_fam_id, a_user.user_id).await?;

    let target = require_member(&mut *tx, a_fam_id, a_target_id).await?;

    if target.is_owner
    {
        return Err(ApiError::Conflict("OWNER_PROTECTED"));
    }

    if target.is_admin() && !actor.is_owner
    {
        return Err(ApiError::Forbidden);
    }

    drop_membership(&mut tx, a_fam_id, a_target_id).await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn transfer_ownership(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<TransferOwnershipRequest>,
) -> Result<StatusCode, ApiError>
{
    let mut tx = a_state.db.begin().await?;
    lock_family(&mut tx, a_fam_id).await?;
    require_owner(&mut *tx, a_fam_id, a_user.user_id).await?;

    let target = member_access(&mut *tx, a_fam_id, a_req.user_id)
        .await?
        .ok_or(ApiError::Validation("user_id"))?;

    if target.is_owner
    {
        return Err(ApiError::Validation("user_id"));
    }

    sqlx::query!(
        "UPDATE family_mems SET role = 'admin' WHERE family_id = $1 AND user_id = $2",
        a_fam_id,
        a_req.user_id
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "UPDATE families SET owner_id = $2 WHERE id = $1",
        a_fam_id,
        a_req.user_id
    )
    .execute(&mut *tx)
    .await?;

    sqlx::query!(
        "DELETE FROM family_invites WHERE family_id = $1 AND role = 'admin'",
        a_fam_id
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn create_invite(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
    ApiJson(a_req): ApiJson<CreateInviteRequest>,
) -> Result<(StatusCode, Json<CreatedInviteDto>), ApiError>
{
    let label = clean_optional_text(a_req.label.as_deref(), MAX_NAME_LEN, "label")?;
    a_state
        .limiter
        .hit(&format!("invite-create:{}", a_user.user_id), &INVITE_CREATE_PER_USER)?;

    let mut tx = a_state.db.begin().await?;
    lock_family(&mut tx, a_fam_id).await?;
    let actor = require_admin(&mut *tx, a_fam_id, a_user.user_id).await?;

    if a_req.role == MemberRole::Admin && !actor.is_owner
    {
        return Err(ApiError::Forbidden);
    }

    sqlx::query!(
        "DELETE FROM family_invites WHERE family_id = $1 AND expires_ts <= NOW()",
        a_fam_id
    )
    .execute(&mut *tx)
    .await?;

    let active_count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM family_invites WHERE family_id = $1"#,
        a_fam_id
    )
    .fetch_one(&mut *tx)
    .await?;

    if active_count >= MAX_ACTIVE_INVITES
    {
        return Err(ApiError::Conflict("TOO_MANY_INVITES"));
    }

    let code = invite_code::generate();
    let normalized = invite_code::normalize(&code).ok_or_else(|| ApiError::internal("invite code generation"))?;
    let expires_ts = Utc::now() + Duration::days(INVITE_TTL_DAYS);

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO family_invites (family_id, code_hash, role, label, invited_by, expires_ts)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id
        "#,
        a_fam_id,
        invite_code::hash(&normalized),
        a_req.role as MemberRole,
        label,
        a_user.user_id,
        expires_ts
    )
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;

    let created = CreatedInviteDto {
        id,
        code,
        role: a_req.role,
        label,
        expires_ts,
    };

    Ok((StatusCode::CREATED, Json(created)))
}

pub async fn list_family_invites(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath(a_fam_id): ApiPath<Uuid>,
) -> Result<Json<Vec<FamInviteDto>>, ApiError>
{
    require_admin(&a_state.db, a_fam_id, a_user.user_id).await?;

    let invites = sqlx::query_as!(
        FamInviteDto,
        r#"
        SELECT id, role AS "role: MemberRole", label, created_ts, expires_ts
        FROM family_invites
        WHERE family_id = $1 AND expires_ts > NOW()
        ORDER BY created_ts
        "#,
        a_fam_id
    )
    .fetch_all(&a_state.db)
    .await?;

    Ok(Json(invites))
}

pub async fn revoke_family_invite(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiPath((a_fam_id, a_invite_id)): ApiPath<(Uuid, Uuid)>,
) -> Result<StatusCode, ApiError>
{
    require_admin(&a_state.db, a_fam_id, a_user.user_id).await?;

    let result = sqlx::query!(
        "DELETE FROM family_invites WHERE id = $1 AND family_id = $2",
        a_invite_id,
        a_fam_id
    )
    .execute(&a_state.db)
    .await?;

    if result.rows_affected() == 0
    {
        return Err(ApiError::NotFound);
    }

    Ok(StatusCode::NO_CONTENT)
}

pub async fn accept_invite(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ClientIp(a_ip): ClientIp,
    ApiJson(a_req): ApiJson<AcceptInviteRequest>,
) -> Result<Json<AcceptInviteResponse>, ApiError>
{
    a_state.limiter.hit(
        &format!("invite-accept-user:{}", a_user.user_id),
        &INVITE_ACCEPT_PER_USER,
    )?;
    a_state
        .limiter
        .hit(&format!("invite-accept-ip:{a_ip}"), &INVITE_ACCEPT_PER_IP)?;

    let normalized = invite_code::normalize(&a_req.code).ok_or(ApiError::NotFound)?;

    let mut tx = a_state.db.begin().await?;

    let invite = sqlx::query!(
        r#"
        DELETE FROM family_invites
        WHERE code_hash = $1 AND expires_ts > NOW()
        RETURNING family_id, role AS "role: MemberRole"
        "#,
        invite_code::hash(&normalized)
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(ApiError::NotFound)?;

    lock_family(&mut tx, invite.family_id).await?;

    sqlx::query!(
        "INSERT INTO family_mems (family_id, user_id, role) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
        invite.family_id,
        a_user.user_id,
        invite.role as MemberRole
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    Ok(Json(AcceptInviteResponse {
        family_id: invite.family_id,
    }))
}

async fn drop_membership(a_conn: &mut PgConnection, a_fam_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    revoke_invites_by(a_conn, a_fam_id, a_user_id).await?;

    sqlx::query!(
        "DELETE FROM family_mems WHERE family_id = $1 AND user_id = $2",
        a_fam_id,
        a_user_id
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(())
}

async fn revoke_invites_by(a_conn: &mut PgConnection, a_fam_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query!(
        "DELETE FROM family_invites WHERE family_id = $1 AND invited_by = $2",
        a_fam_id,
        a_user_id
    )
    .execute(&mut *a_conn)
    .await?;

    Ok(())
}

async fn load_family_detail(a_db: &PgPool, a_fam_id: Uuid, a_access: FamAccess) -> Result<FamDetailDto, ApiError>
{
    let name = sqlx::query_scalar!("SELECT name FROM families WHERE id = $1", a_fam_id)
        .fetch_optional(a_db)
        .await?
        .ok_or(ApiError::NotFound)?;

    let members = sqlx::query_as!(
        FamMemberDto,
        r#"
        SELECT
            u.id,
            u.first_name,
            u.last_name,
            fm.role AS "role: MemberRole",
            (f.owner_id = fm.user_id) AS "is_owner!"
        FROM family_mems fm
        JOIN families f ON f.id = fm.family_id
        JOIN users u ON u.id = fm.user_id
        WHERE fm.family_id = $1
        ORDER BY (f.owner_id = fm.user_id) DESC, fm.joined_ts
        "#,
        a_fam_id
    )
    .fetch_all(a_db)
    .await?;

    Ok(FamDetailDto {
        id: a_fam_id,
        name,
        my_role: a_access.role,
        is_owner: a_access.is_owner,
        is_routine_shared: a_access.is_routine_shared,
        members,
    })
}
