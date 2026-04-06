CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TYPE meas_data_t AS ENUM ('absolute', 'percentage');
CREATE TYPE meas_calc_t AS ENUM ('snapshot', 'delta');
CREATE TYPE recur_freq_t AS ENUM ('once', 'daily', 'weekly', 'monthly', 'quarterly', 'yearly');
CREATE TYPE mem_role_t AS ENUM ('admin', 'standard');
CREATE TYPE acc_type_t AS ENUM ('cash', 'card', 'bank_acc');
CREATE TYPE budget_period_t AS ENUM ('weekly', 'monthly', 'quarterly', 'yearly');
CREATE TYPE tx_type_t AS ENUM ('income', 'expense', 'transfer');
CREATE TYPE ext_prov_t AS ENUM ('plaid', 'saltedge', 'manual');
CREATE TYPE ex_type_t AS ENUM ('cardio', 'strength', 'flexibility', 'mixed');
CREATE TYPE meal_t AS ENUM ('breakfast', 'lunch', 'dinner', 'snack');
CREATE TYPE curr_status_t AS ENUM ('home', 'work', 'school', 'gym', 'transit', 'other');
CREATE TYPE bank_type_t AS ENUM ('monobank', 'aib', 'other');
CREATE TYPE item_t AS ENUM ('product', 'service', 'food');

CREATE TYPE muscle_grp_t AS ENUM ('chest', 'back', 'legs', 'shoulders', 'arms', 'core', 'full_body', 'cardio');

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(255) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    birth_date DATE NOT NULL,
    gender VARCHAR(10),
    avatar_url TEXT,
    is_verified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE body_snaps (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    weight NUMERIC(5, 2) NOT NULL,
    height NUMERIC(5, 2) NOT NULL,
    fat_pct NUMERIC(4, 2),
    musc_pct NUMERIC(4, 2),
    skel_musc_pct NUMERIC(4, 2),
    rec_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_body_snaps_user_ts ON body_snaps(user_id, rec_ts DESC);

CREATE TABLE families (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE meas_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) UNIQUE NOT NULL,
    unit VARCHAR(50) NOT NULL,
    data_t meas_data_t NOT NULL,
    calc_t meas_calc_t NOT NULL
);

CREATE TABLE countries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code VARCHAR(3) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL
);

CREATE TABLE currencies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code VARCHAR(3) UNIQUE NOT NULL
);

CREATE TABLE items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    type item_t NOT NULL,
    name VARCHAR(255) NOT NULL
);

CREATE TABLE food_nutr (
    item_id UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    kcal NUMERIC(6, 2) NOT NULL,
    prot NUMERIC(6, 2) NOT NULL,
    fat NUMERIC(6, 2) NOT NULL,
    carb NUMERIC(6, 2) NOT NULL
);

CREATE TABLE places (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL
);

CREATE TABLE user_prefs (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    def_range_hrs INT NOT NULL DEFAULT 24,
    vis_fams JSONB NOT NULL DEFAULT '[]',
    vis_users JSONB NOT NULL DEFAULT '[]'
);

CREATE TABLE family_mems (
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    role mem_role_t NOT NULL DEFAULT 'standard',
    joined_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (family_id, user_id)
);

CREATE TABLE meas_convs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    src_meas_id UUID REFERENCES meas_types(id) ON DELETE CASCADE,
    tgt_meas_id UUID REFERENCES meas_types(id) ON DELETE CASCADE,
    rate NUMERIC(18, 6) NOT NULL,
    eff_ts TIMESTAMPTZ NOT NULL,
    UNIQUE (src_meas_id, tgt_meas_id, eff_ts)
);

CREATE TABLE user_meas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    meas_id UUID REFERENCES meas_types(id) ON DELETE CASCADE,
    val NUMERIC(18, 6) NOT NULL,
    rec_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE cities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    country_id UUID NOT NULL REFERENCES countries(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    UNIQUE (country_id, name)
);

CREATE TABLE currency_rates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    base_curr_id UUID NOT NULL REFERENCES currencies(id) ON DELETE CASCADE,
    target_curr_id UUID NOT NULL REFERENCES currencies(id) ON DELETE CASCADE,
    rate NUMERIC(18, 6) NOT NULL,
    date DATE NOT NULL,
    UNIQUE(base_curr_id, target_curr_id, date)
);
CREATE INDEX idx_currency_rates_date ON currency_rates(date);

CREATE TABLE item_meas (
    item_id UUID REFERENCES items(id) ON DELETE CASCADE,
    meas_id UUID REFERENCES meas_types(id) ON DELETE CASCADE,
    val NUMERIC(10, 2) NOT NULL,
    PRIMARY KEY (item_id, meas_id)
);

CREATE TABLE streets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    city_id UUID NOT NULL REFERENCES cities(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    UNIQUE (city_id, name)
);

CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    curr_id UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    account_type acc_type_t NOT NULL,
    bank_type bank_type_t,
    name VARCHAR(255) NOT NULL,
    mask VARCHAR(20),
    sync_credentials JSONB,
    ext_prov ext_prov_t NOT NULL DEFAULT 'manual',
    ext_acc_id VARCHAR(255) UNIQUE,
    last_sync_ts TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT acc_owner_chk CHECK (
        (user_id IS NOT NULL AND family_id IS NULL) OR
        (user_id IS NULL AND family_id IS NOT NULL)
    )
);

CREATE TABLE place_addrs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    place_id UUID NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    is_main BOOLEAN NOT NULL DEFAULT FALSE,
    country_id UUID NOT NULL REFERENCES countries(id) ON DELETE RESTRICT, 
    city_id UUID NOT NULL REFERENCES cities(id) ON DELETE RESTRICT, 
    street_id UUID NOT NULL REFERENCES streets(id) ON DELETE RESTRICT,
    house_num VARCHAR(50) NOT NULL,
    apt VARCHAR(50),
    zip VARCHAR(50) NOT NULL,
    merchant_id VARCHAR(255)
);
CREATE UNIQUE INDEX idx_place_main_addr ON place_addrs(place_id) WHERE is_main = true;

CREATE TABLE item_prices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    item_id UUID REFERENCES items(id) ON DELETE CASCADE,
    place_id UUID REFERENCES places(id) ON DELETE CASCADE,
    currency_id UUID REFERENCES currencies(id) ON DELETE RESTRICT,
    price NUMERIC(15, 2) NOT NULL,
    rec_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE dict_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) UNIQUE NOT NULL,
    place_id UUID REFERENCES places(id) ON DELETE SET NULL
);

CREATE TABLE event_impacts (
    event_id UUID REFERENCES dict_events(id) ON DELETE CASCADE,
    meas_id UUID REFERENCES meas_types(id) ON DELETE CASCADE,
    val NUMERIC(10, 2) NOT NULL,
    PRIMARY KEY (event_id, meas_id)
);

CREATE TABLE plans (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    event_id UUID REFERENCES dict_events(id) ON DELETE CASCADE,
    freq recur_freq_t NOT NULL DEFAULT 'once',
    recur_pattern JSONB,
    valid_from TIMESTAMPTZ NOT NULL,
    valid_to TIMESTAMPTZ
);

CREATE TABLE plan_execs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    plan_id UUID REFERENCES plans(id) ON DELETE CASCADE,
    start_ts TIMESTAMPTZ NOT NULL,
    end_ts TIMESTAMPTZ NOT NULL,
    completed_ts TIMESTAMPTZ
);

CREATE TABLE plan_occ (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    plan_id UUID REFERENCES plans(id) ON DELETE CASCADE,
    occ_start_ts TIMESTAMPTZ NOT NULL,
    occ_end_ts TIMESTAMPTZ NOT NULL,
    status curr_status_t NOT NULL
);
CREATE INDEX idx_plan_occ_time ON plan_occ(occ_start_ts, occ_end_ts);


CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id),
    account_id UUID NOT NULL REFERENCES accounts(id),
    curr_id UUID NOT NULL REFERENCES currencies(id),
    amount NUMERIC(15, 2) NOT NULL,
    tx_type tx_type_t NOT NULL,
    date TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_transactions_account_date ON transactions(account_id, date);
CREATE INDEX idx_transactions_user_date ON transactions(user_id, date);

CREATE TABLE tx_cats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    type tx_type_t NOT NULL,
    parent_id UUID REFERENCES tx_cats(id) ON DELETE SET NULL
);

CREATE TABLE tx_ledger (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    acc_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
    cat_id UUID REFERENCES tx_cats(id) ON DELETE RESTRICT,
    actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    ref_tx_id UUID REFERENCES tx_ledger(id) ON DELETE SET NULL,
    amount NUMERIC(18, 6) NOT NULL,
    tx_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_tx_ledger_acc_ts ON tx_ledger(acc_id, tx_ts);

CREATE TABLE acc_snaps (
    acc_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
    snap_ts TIMESTAMPTZ NOT NULL,
    balance NUMERIC(18, 6) NOT NULL,
    PRIMARY KEY (acc_id, snap_ts)
);

CREATE TABLE dict_exs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) UNIQUE NOT NULL,
    type ex_type_t NOT NULL,
    met_val NUMERIC(5, 2) NOT NULL,
    is_custom BOOLEAN NOT NULL DEFAULT FALSE,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE TABLE dict_ex_muscles (
    ex_id UUID REFERENCES dict_exs(id) ON DELETE CASCADE,
    muscle muscle_grp_t NOT NULL,
    pct NUMERIC(5, 2) NOT NULL CHECK (pct > 0 AND pct <= 100),
    PRIMARY KEY (ex_id, muscle)
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

INSERT INTO countries (code, name) VALUES 
('IRL', 'Ireland'), ('UKR', 'Ukraine'), ('POL', 'Poland'), ('GBR', 'United Kingdom')
ON CONFLICT DO NOTHING;

INSERT INTO currencies (code) VALUES 
('USD'), ('EUR'), ('RUB'), ('UAH'), ('GBP'), ('KZT'), ('PLN'), ('BYN') 
ON CONFLICT DO NOTHING;