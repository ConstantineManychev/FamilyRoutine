use shared_schema::AccountType;
use sqlx::PgExecutor;
use uuid::Uuid;

use crate::domain::errors::ApiError;

pub struct AccountAccess
{
    pub id: Uuid,
    pub curr_id: Uuid,
    pub account_type: AccountType,
    pub conn_id: Option<Uuid>,
    pub is_editor: bool,
}

impl AccountAccess
{
    pub fn is_manual(&self) -> bool
    {
        self.conn_id.is_none()
    }
}

pub async fn account_access<'e, E>(a_db: E, a_account_id: Uuid, a_user_id: Uuid) -> Result<AccountAccess, ApiError>
where
    E: PgExecutor<'e>,
{
    sqlx::query_as!(
        AccountAccess,
        r#"
        SELECT
            a.id,
            a.curr_id,
            a.account_type AS "account_type: AccountType",
            a.conn_id,
            BOOL_OR(v.is_editor) AS "is_editor!"
        FROM accounts a
        JOIN account_viewers v ON v.account_id = a.id
        WHERE a.id = $1 AND v.viewer_id = $2
        GROUP BY a.id
        "#,
        a_account_id,
        a_user_id
    )
    .fetch_optional(a_db)
    .await?
    .ok_or(ApiError::NotFound)
}

pub async fn require_account_editor<'e, E>(
    a_db: E,
    a_account_id: Uuid,
    a_user_id: Uuid,
) -> Result<AccountAccess, ApiError>
where
    E: PgExecutor<'e>,
{
    let access = account_access(a_db, a_account_id, a_user_id).await?;

    if !access.is_editor
    {
        return Err(ApiError::Forbidden);
    }

    Ok(access)
}
