ALTER TABLE family_mems
    DROP COLUMN is_routine_shared,
    DROP COLUMN is_prices_shared,
    DROP COLUMN is_body_shared,
    DROP COLUMN is_composition_shared,
    DROP COLUMN is_measures_shared,
    DROP COLUMN is_training_shared,
    DROP COLUMN is_meals_shared;

CREATE FUNCTION can_manage_person(a_viewer_id UUID, a_person_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT a_viewer_id = a_person_id OR EXISTS (
        SELECT 1
        FROM users u
        WHERE u.id = a_person_id AND u.is_managed AND (
            u.managed_by = a_viewer_id
            OR EXISTS (
                SELECT 1
                FROM family_mems child
                JOIN family_mems actor ON actor.family_id = child.family_id
                JOIN families f ON f.id = child.family_id
                WHERE child.user_id = u.id AND actor.user_id = a_viewer_id
                  AND (actor.role = 'admin' OR f.owner_id = a_viewer_id)
            )
        )
    )
$$;
