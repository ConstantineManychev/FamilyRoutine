CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE families (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    country VARCHAR(100),
    region VARCHAR(100),
    city VARCHAR(100),
    street VARCHAR(255),
    building VARCHAR(50),
    apartment VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(255) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    birth_date DATE NOT NULL,
    birth_time TIME,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE family_members (
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (family_id, user_id)
);

CREATE TYPE measurement_data_type AS ENUM ('absolute', 'percentage');
CREATE TYPE measurement_calc_type AS ENUM ('snapshot', 'delta');

CREATE TABLE measurement_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) UNIQUE NOT NULL,
    data_type measurement_data_type NOT NULL,
    calc_type measurement_calc_type NOT NULL
);

CREATE TABLE measurement_conversions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_measurement_id UUID REFERENCES measurement_types(id) ON DELETE CASCADE,
    target_measurement_id UUID REFERENCES measurement_types(id) ON DELETE CASCADE,
    exchange_rate NUMERIC(18, 6) NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL,
    UNIQUE (source_measurement_id, target_measurement_id, effective_from)
);

CREATE TABLE user_measurements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    measurement_type_id UUID REFERENCES measurement_types(id) ON DELETE CASCADE,
    recorded_at TIMESTAMPTZ NOT NULL,
    numeric_value NUMERIC(18, 6) NOT NULL
);

CREATE TABLE event_definitions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) UNIQUE NOT NULL,
    impacted_measurement_id UUID REFERENCES measurement_types(id) ON DELETE SET NULL,
    calculation_strategy_id VARCHAR(100) NOT NULL 
);

CREATE TYPE recurrence_frequency AS ENUM ('once', 'daily', 'weekly', 'monthly', 'quarterly', 'yearly');

CREATE TABLE event_plans (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_definition_id UUID REFERENCES event_definitions(id) ON DELETE CASCADE,
    frequency recurrence_frequency NOT NULL,
    recurrence_pattern JSONB,
    valid_from TIMESTAMPTZ NOT NULL,
    valid_until TIMESTAMPTZ
);

CREATE TABLE event_schedules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_plan_id UUID REFERENCES event_plans(id) ON DELETE CASCADE,
    scheduled_start_at TIMESTAMPTZ NOT NULL,
    scheduled_end_at TIMESTAMPTZ NOT NULL,
    actual_completed_at TIMESTAMPTZ
);