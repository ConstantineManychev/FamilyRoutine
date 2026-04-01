CREATE TYPE ext_prov_t AS ENUM ('plaid', 'saltedge', 'manual');
CREATE TYPE ex_type_t AS ENUM ('cardio', 'strength', 'flexibility', 'mixed');
CREATE TYPE meal_t AS ENUM ('breakfast', 'lunch', 'dinner', 'snack');
CREATE TYPE curr_status_t AS ENUM ('home', 'work', 'school', 'gym', 'transit', 'other');

ALTER TABLE accounts
ADD COLUMN ext_prov ext_prov_t NOT NULL DEFAULT 'manual',
ADD COLUMN ext_acc_id VARCHAR(255) UNIQUE,
ADD COLUMN last_sync_ts TIMESTAMPTZ;

CREATE TABLE dict_exs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) UNIQUE NOT NULL,
    type ex_type_t NOT NULL,
    met_val NUMERIC(5, 2) NOT NULL,
    is_custom BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE TABLE user_workouts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    start_ts TIMESTAMPTZ NOT NULL,
    end_ts TIMESTAMPTZ,
    kcal_burned NUMERIC(8, 2)
);

CREATE TABLE workout_exs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workout_id UUID REFERENCES user_workouts(id) ON DELETE CASCADE,
    ex_id UUID REFERENCES dict_exs(id) ON DELETE RESTRICT,
    duration_sec INT,
    sets INT,
    reps INT,
    weight_kg NUMERIC(6, 2),
    kcal_burned NUMERIC(8, 2) NOT NULL
);

CREATE TABLE user_meals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    meal meal_t NOT NULL,
    consumed_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    total_kcal NUMERIC(8, 2) NOT NULL
);

CREATE TABLE meal_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    meal_id UUID REFERENCES user_meals(id) ON DELETE CASCADE,
    item_id UUID REFERENCES items(id) ON DELETE RESTRICT,
    qty NUMERIC(8, 2) NOT NULL,
    meas_id UUID REFERENCES meas_types(id) ON DELETE RESTRICT,
    kcal NUMERIC(8, 2) NOT NULL
);

CREATE TABLE user_curr_status (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    status curr_status_t NOT NULL,
    active_plan_id UUID REFERENCES plans(id) ON DELETE SET NULL,
    loc_lat NUMERIC(10, 7),
    loc_lng NUMERIC(10, 7),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);