ALTER TABLE status_marks ADD COLUMN is_planned BOOLEAN NOT NULL DEFAULT FALSE;
DROP INDEX uq_status_marks_user_start;
CREATE UNIQUE INDEX uq_status_marks_user_start ON status_marks(user_id, start_ts) WHERE NOT is_planned;
CREATE INDEX idx_status_marks_planned ON status_marks(user_id) WHERE is_planned;

ALTER TABLE plan_instances ADD COLUMN is_session_auto BOOLEAN NOT NULL DEFAULT FALSE;
