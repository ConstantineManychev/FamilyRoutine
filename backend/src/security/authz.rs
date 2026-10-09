use shared_schema::MemberRole;
use sqlx::{PgConnection, PgExecutor};
use uuid::Uuid;

use crate::domain::errors::ApiError;

pub async fn member_role<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<Option<MemberRole>, ApiError>
where
    E: PgExecutor<'e>,
{
    let role = sqlx::query_scalar!(
        r#"SELECT role AS "role: MemberRole" FROM family_mems WHERE family_id = $1 AND user_id = $2"#,
        a_fam_id,
        a_user_id
    )
    .fetch_optional(a_db)
    .await?;

    Ok(role)
}

pub async fn require_member<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<MemberRole, ApiError>
where
    E: PgExecutor<'e>,
{
    member_role(a_db, a_fam_id, a_user_id).await?.ok_or(ApiError::NotFound)
}

pub async fn require_admin<'e, E>(a_db: E, a_fam_id: Uuid, a_user_id: Uuid) -> Result<(), ApiError>
where
    E: PgExecutor<'e>,
{
    match require_member(a_db, a_fam_id, a_user_id).await?
    {
        MemberRole::Admin => Ok(()),
        MemberRole::Standard => Err(ApiError::Forbidden),
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

pub async fn admin_count(a_conn: &mut PgConnection, a_fam_id: Uuid) -> Result<i64, ApiError>
{
    let count = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!" FROM family_mems WHERE family_id = $1 AND role = 'admin'"#,
        a_fam_id
    )
    .fetch_one(&mut *a_conn)
    .await?;

    Ok(count)
}
