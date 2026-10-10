use shared_schema::MemberRole;
use sqlx::{PgConnection, PgExecutor};
use uuid::Uuid;

use crate::domain::errors::ApiError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FamAccess
{
    pub role: MemberRole,
    pub is_owner: bool,
    pub is_routine_shared: bool,
}

impl FamAccess
{
    pub fn is_admin(&self) -> bool
    {
        self.is_owner || self.role == MemberRole::Admin
    }
}

pub async fn member_access<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<Option<FamAccess>, ApiError>
where
    E: PgExecutor<'e>,
{
    let row = sqlx::query!(
        r#"
        SELECT fm.role AS "role: MemberRole", (f.owner_id = fm.user_id) AS "is_owner!", fm.is_routine_shared
        FROM family_mems fm
        JOIN families f ON f.id = fm.family_id
        WHERE fm.family_id = $1 AND fm.user_id = $2
        "#,
        a_fam_id,
        a_user_id
    )
    .fetch_optional(a_db)
    .await?;

    Ok(row.map(|r| FamAccess {
        role: r.role,
        is_owner: r.is_owner,
        is_routine_shared: r.is_routine_shared,
    }))
}

pub async fn require_member<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<FamAccess, ApiError>
where
    E: PgExecutor<'e>,
{
    member_access(a_db, a_fam_id, a_user_id)
        .await?
        .ok_or(ApiError::NotFound)
}

pub async fn require_admin<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<FamAccess, ApiError>
where
    E: PgExecutor<'e>,
{
    let access = require_member(a_db, a_fam_id, a_user_id).await?;

    if access.is_admin()
    {
        Ok(access)
    }
    else
    {
        Err(ApiError::Forbidden)
    }
}

pub async fn require_owner<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<FamAccess, ApiError>
where
    E: PgExecutor<'e>,
{
    let access = require_member(a_db, a_fam_id, a_user_id).await?;

    if access.is_owner
    {
        Ok(access)
    }
    else
    {
        Err(ApiError::Forbidden)
    }
}

pub async fn lock_family(a_conn: &mut PgConnection, a_fam_id: Uuid) -> Result<(), ApiError>
{
    sqlx::query_scalar!("SELECT id FROM families WHERE id = $1 FOR UPDATE", a_fam_id)
        .fetch_optional(&mut *a_conn)
        .await?
        .ok_or(ApiError::NotFound)?;

    Ok(())
}
