CREATE TYPE plan_timing_t AS ENUM ('fixed', 'window');
CREATE TYPE plan_repeat_t AS ENUM ('once', 'daily', 'weekly', 'monthly');
CREATE TYPE plan_state_t AS ENUM ('planned', 'done', 'skipped');

CREATE TABLE plan_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(100) NOT NULL,
    note VARCHAR(500),
    category curr_status_t,
    timing plan_timing_t NOT NULL,
    start_date DATE NOT NULL,
    start_time TIME NOT NULL,
    window_min INT CHECK (window_min BETWEEN 5 AND 1440),
    duration_min INT NOT NULL CHECK (duration_min BETWEEN 5 AND 1440),
    tz VARCHAR(64) NOT NULL,
    repeat plan_repeat_t NOT NULL DEFAULT 'once',
    repeat_every INT NOT NULL DEFAULT 1 CHECK (repeat_every BETWEEN 1 AND 365),
    weekday_mask INT NOT NULL DEFAULT 0 CHECK (weekday_mask BETWEEN 0 AND 127),
    until_date DATE,
    program_id UUID REFERENCES training_programs(id) ON DELETE SET NULL,
    day_id UUID REFERENCES program_days(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT plan_events_window_chk CHECK (
        (timing = 'window') = (window_min IS NOT NULL) AND (window_min IS NULL OR duration_min <= window_min)
    ),
    CONSTRAINT plan_events_weekly_chk CHECK (repeat <> 'weekly' OR weekday_mask > 0),
    CONSTRAINT plan_events_until_chk CHECK (until_date IS NULL OR until_date >= start_date)
);
CREATE INDEX idx_plan_events_user ON plan_events(user_id);
CREATE INDEX idx_plan_events_program ON plan_events(program_id) WHERE program_id IS NOT NULL;

CREATE TABLE plan_instances (
    event_id UUID NOT NULL REFERENCES plan_events(id) ON DELETE CASCADE,
    occ_date DATE NOT NULL,
    state plan_state_t NOT NULL DEFAULT 'planned',
    moved_date DATE,
    moved_time TIME,
    session_id UUID REFERENCES workout_sessions(id) ON DELETE SET NULL,
    done_ts TIMESTAMPTZ,
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, occ_date),
    CONSTRAINT plan_instances_move_chk CHECK ((moved_date IS NULL) = (moved_time IS NULL))
);
CREATE INDEX idx_plan_instances_moved ON plan_instances(event_id, moved_date) WHERE moved_date IS NOT NULL;
CREATE UNIQUE INDEX uq_plan_instances_session ON plan_instances(session_id) WHERE session_id IS NOT NULL;
