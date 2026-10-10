ALTER TYPE curr_status_t ADD VALUE IF NOT EXISTS 'sleep';
ALTER TYPE curr_status_t ADD VALUE IF NOT EXISTS 'meal';
ALTER TYPE curr_status_t ADD VALUE IF NOT EXISTS 'leisure';

CREATE TABLE status_marks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status curr_status_t NOT NULL,
    note VARCHAR(200),
    start_ts TIMESTAMPTZ NOT NULL,
    end_ts TIMESTAMPTZ,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT status_marks_range_chk CHECK (end_ts IS NULL OR end_ts > start_ts)
);
CREATE INDEX idx_status_marks_user_start ON status_marks(user_id, start_ts DESC);
CREATE UNIQUE INDEX uq_status_marks_user_start ON status_marks(user_id, start_ts);

ALTER TABLE family_mems ADD COLUMN is_routine_shared BOOLEAN NOT NULL DEFAULT TRUE;

CREATE TYPE widget_kind_t AS ENUM ('my_status', 'family_timeline', 'cashflow', 'family_list');

CREATE TABLE dashboards (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
    sort_ord INT NOT NULL DEFAULT 0,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_dashboards_user ON dashboards(user_id, sort_ord);

CREATE TABLE dash_widgets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    dashboard_id UUID NOT NULL REFERENCES dashboards(id) ON DELETE CASCADE,
    kind widget_kind_t NOT NULL,
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    sort_ord INT NOT NULL DEFAULT 0,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT dash_widgets_family_chk CHECK ((kind = 'family_timeline') = (family_id IS NOT NULL))
);
CREATE INDEX idx_dash_widgets_dashboard ON dash_widgets(dashboard_id, sort_ord);
