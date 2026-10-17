ALTER TYPE waste_reason_t ADD VALUE IF NOT EXISTS 'expired';

ALTER TABLE stock_lots ADD COLUMN expires_on DATE;
ALTER TABLE stock_lots ADD COLUMN warned_on DATE;
ALTER TABLE stock_lots ADD COLUMN is_expiry_done BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_stock_lots_expiry ON stock_lots(expires_on) WHERE expires_on IS NOT NULL AND NOT is_expiry_done;

CREATE FUNCTION stock_lot_reopen() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE stock_lots SET is_expiry_done = FALSE WHERE id = OLD.lot_id AND is_expiry_done;
    RETURN NULL;
END
$$;

CREATE TRIGGER stock_moves_reopen AFTER DELETE ON stock_moves
FOR EACH ROW EXECUTE FUNCTION stock_lot_reopen();

CREATE TYPE notify_kind_t AS ENUM ('plan', 'workout', 'expiring', 'expired');
CREATE TYPE push_state_t AS ENUM ('pending', 'sending', 'sent', 'skipped', 'failed');

CREATE TABLE notify_settings (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    tz VARCHAR(64) NOT NULL DEFAULT 'UTC',
    lang VARCHAR(8) NOT NULL DEFAULT 'en',
    is_plan BOOLEAN NOT NULL DEFAULT TRUE,
    plan_lead_min INT NOT NULL DEFAULT 15 CHECK (plan_lead_min BETWEEN 0 AND 1440),
    is_workout BOOLEAN NOT NULL DEFAULT TRUE,
    workout_lead_min INT NOT NULL DEFAULT 60 CHECK (workout_lead_min BETWEEN 0 AND 1440),
    is_expiring BOOLEAN NOT NULL DEFAULT TRUE,
    is_expired BOOLEAN NOT NULL DEFAULT TRUE,
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE plan_remind_due (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    due_ts TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_plan_remind_due ON plan_remind_due(due_ts);

CREATE TABLE notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind notify_kind_t NOT NULL,
    dedup_key VARCHAR(200) NOT NULL,
    title VARCHAR(200) NOT NULL,
    body VARCHAR(500) NOT NULL,
    link VARCHAR(200) NOT NULL,
    params JSONB NOT NULL DEFAULT '{}'::jsonb,
    push_state push_state_t NOT NULL DEFAULT 'pending',
    push_tries SMALLINT NOT NULL DEFAULT 0,
    push_ts TIMESTAMPTZ,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_ts TIMESTAMPTZ,
    CONSTRAINT notifications_dedup_uq UNIQUE (user_id, dedup_key),
    CONSTRAINT notifications_link_chk CHECK (link LIKE '/app/%')
);

CREATE INDEX idx_notifications_user ON notifications(user_id, created_ts DESC);
CREATE INDEX idx_notifications_unread ON notifications(user_id) WHERE read_ts IS NULL;
CREATE INDEX idx_notifications_push ON notifications(created_ts) WHERE push_state IN ('pending', 'sending');

CREATE TABLE push_subs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    endpoint_hash BYTEA NOT NULL UNIQUE,
    sealed BYTEA NOT NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_ok_ts TIMESTAMPTZ,
    fail_count INT NOT NULL DEFAULT 0
);

CREATE INDEX idx_push_subs_user ON push_subs(user_id);

INSERT INTO plan_remind_due (user_id, due_ts)
SELECT DISTINCT user_id, NOW() FROM plan_events;
