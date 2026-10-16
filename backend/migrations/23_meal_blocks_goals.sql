ALTER TABLE meal_entries DROP COLUMN meal;
DROP TYPE meal_t;

CREATE TYPE goal_mode_t AS ENUM ('lose', 'maintain', 'gain');

CREATE TABLE nutrition_goals (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    mode goal_mode_t NOT NULL DEFAULT 'maintain',
    pace_kg NUMERIC(3, 2) CHECK (pace_kg > 0 AND pace_kg <= 1.5),
    target_kg NUMERIC(4, 1) CHECK (target_kg >= 20 AND target_kg <= 350),
    is_custom BOOLEAN NOT NULL DEFAULT FALSE,
    custom_kcal NUMERIC(5, 0) CHECK (custom_kcal >= 800 AND custom_kcal <= 6000),
    custom_prot NUMERIC(4, 0) CHECK (custom_prot >= 0 AND custom_prot <= 600),
    custom_fat NUMERIC(4, 0) CHECK (custom_fat >= 0 AND custom_fat <= 400),
    custom_carb NUMERIC(4, 0) CHECK (custom_carb >= 0 AND custom_carb <= 1000),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT nutrition_goals_pace_chk CHECK (mode = 'maintain' OR pace_kg IS NOT NULL),
    CONSTRAINT nutrition_goals_custom_chk CHECK (
        NOT is_custom
        OR (custom_kcal IS NOT NULL AND custom_prot IS NOT NULL AND custom_fat IS NOT NULL AND custom_carb IS NOT NULL)
    )
);
