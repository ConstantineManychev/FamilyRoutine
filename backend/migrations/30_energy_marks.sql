CREATE TABLE energy_marks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ts TIMESTAMPTZ NOT NULL,
    kcal NUMERIC(8, 1) NOT NULL CHECK (kcal >= -100000 AND kcal <= 100000),
    set_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT energy_marks_user_ts_key UNIQUE (user_id, ts)
);
