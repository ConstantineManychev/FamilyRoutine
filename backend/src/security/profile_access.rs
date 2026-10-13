use shared_schema::MetricGroup;
use sqlx::PgConnection;
use uuid::Uuid;

use crate::domain::errors::ApiError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileAccess
{
    pub is_self: bool,
    pub is_manager: bool,
    pub is_managed: bool,
    shared_groups: Vec<MetricGroup>,
    is_training_shared: bool,
}

impl ProfileAccess
{
    pub fn can_see(&self, a_group: MetricGroup) -> bool
    {
        self.is_manager || self.shared_groups.contains(&a_group)
    }

    pub fn can_see_training(&self) -> bool
    {
        self.is_manager || self.is_training_shared
    }

    pub fn require_training(&self) -> Result<(), ApiError>
    {
        if self.can_see_training()
        {
            Ok(())
        }
        else
        {
            Err(ApiError::NotFound)
        }
    }

    pub fn visible_groups(&self) -> Vec<MetricGroup>
    {
        [MetricGroup::Body, MetricGroup::Composition, MetricGroup::Measures]
            .into_iter()
            .filter(|group| self.can_see(*group))
            .collect()
    }

    pub fn require_group(&self, a_group: MetricGroup) -> Result<(), ApiError>
    {
        if self.can_see(a_group)
        {
            Ok(())
        }
        else
        {
            Err(ApiError::NotFound)
        }
    }

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
            (u.id = $1 OR (u.is_managed AND (
                u.managed_by = $1
                OR EXISTS (
                    SELECT 1
                    FROM family_mems child
                    JOIN family_mems actor ON actor.family_id = child.family_id
                    JOIN families f ON f.id = child.family_id
                    WHERE child.user_id = u.id AND actor.user_id = $1 AND (actor.role = 'admin' OR f.owner_id = $1)
                )
            ))) AS "is_manager!",
            EXISTS (
                SELECT 1 FROM family_mems t JOIN family_mems v ON v.family_id = t.family_id
                WHERE t.user_id = u.id AND v.user_id = $1
            ) AS "is_relative!",
            EXISTS (
                SELECT 1 FROM family_mems t JOIN family_mems v ON v.family_id = t.family_id
                WHERE t.user_id = u.id AND v.user_id = $1 AND t.is_body_shared
            ) AS "is_body!",
            EXISTS (
                SELECT 1 FROM family_mems t JOIN family_mems v ON v.family_id = t.family_id
                WHERE t.user_id = u.id AND v.user_id = $1 AND t.is_composition_shared
            ) AS "is_composition!",
            EXISTS (
                SELECT 1 FROM family_mems t JOIN family_mems v ON v.family_id = t.family_id
                WHERE t.user_id = u.id AND v.user_id = $1 AND t.is_measures_shared
            ) AS "is_measures!",
            EXISTS (
                SELECT 1 FROM family_mems t JOIN family_mems v ON v.family_id = t.family_id
                WHERE t.user_id = u.id AND v.user_id = $1 AND t.is_training_shared
            ) AS "is_training!"
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

    let shared_groups = [
        (row.is_body, MetricGroup::Body),
        (row.is_composition, MetricGroup::Composition),
        (row.is_measures, MetricGroup::Measures),
    ]
    .into_iter()
    .filter_map(|(is_shared, group)| is_shared.then_some(group))
    .collect();

    Ok(ProfileAccess {
        is_self: a_viewer_id == a_target_id,
        is_manager: row.is_manager,
        is_managed: row.is_managed,
        shared_groups,
        is_training_shared: row.is_training,
    })
}
