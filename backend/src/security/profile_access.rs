use sqlx::PgConnection;
use uuid::Uuid;

use crate::domain::errors::ApiError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileAccess
{
    pub is_self: bool,
    pub is_manager: bool,
    pub is_managed: bool,
}

impl ProfileAccess
{
    pub fn require_manager(&self) -> Result<(), ApiError>
    {
        if self.is_manager
        {
            Ok(())
        }
        else
        {
            Err(ApiError::Forbidden)
        }
    }
}

pub async fn profile_access(
    a_conn: &mut PgConnection,
    a_viewer_id: Uuid,
    a_target_id: Uuid,
) -> Result<ProfileAccess, ApiError>
{
    let row = sqlx::query!(
        r#"
        SELECT
            u.is_managed,
            can_manage_person($1, u.id) AS "is_manager!",
            EXISTS (
                SELECT 1 FROM family_mems t JOIN family_mems v ON v.family_id = t.family_id
                WHERE t.user_id = u.id AND v.user_id = $1
            ) AS "is_relative!"
        FROM users u
        WHERE u.id = $2
        "#,
        a_viewer_id,
        a_target_id
    )
    .fetch_optional(&mut *a_conn)
    .await?
    .ok_or(ApiError::NotFound)?;

    if !row.is_manager && !row.is_relative
    {
        return Err(ApiError::NotFound);
    }

    Ok(ProfileAccess {
        is_self: a_viewer_id == a_target_id,
        is_manager: row.is_manager,
        is_managed: row.is_managed,
    })
}

pub async fn acting_for(
    a_conn: &mut PgConnection,
    a_viewer_id: Uuid,
    a_person_id: Option<Uuid>,
) -> Result<Uuid, ApiError>
{
    match a_person_id
    {
        Some(person_id) if person_id != a_viewer_id =>
        {
            profile_access(a_conn, a_viewer_id, person_id)
                .await?
                .require_manager()?;
            Ok(person_id)
        }
        _ => Ok(a_viewer_id),
    }
}

pub async fn is_editor(a_conn: &mut PgConnection, a_viewer_id: Uuid, a_owner_id: Uuid) -> Result<bool, ApiError>
{
    if a_viewer_id == a_owner_id
    {
        return Ok(true);
    }
    Ok(profile_access(a_conn, a_viewer_id, a_owner_id).await?.is_manager)
}

pub async fn require_editor(a_conn: &mut PgConnection, a_viewer_id: Uuid, a_owner_id: Uuid) -> Result<(), ApiError>
{
    if is_editor(a_conn, a_viewer_id, a_owner_id).await?
    {
        Ok(())
    }
    else
    {
        Err(ApiError::Forbidden)
    }
}
