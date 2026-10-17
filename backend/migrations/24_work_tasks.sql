CREATE TYPE task_kind_t AS ENUM ('general', 'day');
CREATE TYPE task_event_t AS ENUM ('created', 'edited', 'progress', 'done', 'reopened', 'deleted');
CREATE TYPE task_field_t AS ENUM ('title', 'note', 'kind', 'date');

CREATE TABLE work_tasks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind task_kind_t NOT NULL,
    title VARCHAR(200) NOT NULL CHECK (LENGTH(TRIM(title)) > 0),
    note VARCHAR(2000),
    start_on DATE NOT NULL,
    done_on DATE,
    done_ts TIMESTAMPTZ,
    deleted_ts TIMESTAMPTZ,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT work_tasks_done_chk CHECK ((done_on IS NULL) = (done_ts IS NULL))
);

CREATE INDEX idx_work_tasks_day ON work_tasks(user_id, start_on) WHERE deleted_ts IS NULL;
CREATE INDEX idx_work_tasks_open ON work_tasks(user_id) WHERE deleted_ts IS NULL AND kind = 'general';

CREATE TABLE work_task_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    seq BIGINT GENERATED ALWAYS AS IDENTITY,
    task_id UUID NOT NULL REFERENCES work_tasks(id) ON DELETE CASCADE,
    kind task_event_t NOT NULL,
    field task_field_t,
    old_value VARCHAR(2000),
    new_value VARCHAR(2000),
    report VARCHAR(2000),
    event_on DATE NOT NULL,
    status_mark_id UUID,
    event_ts TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT work_task_events_edit_chk CHECK ((kind = 'edited') = (field IS NOT NULL))
);

CREATE INDEX idx_work_task_events_task ON work_task_events(task_id, seq);
CREATE INDEX idx_work_task_events_mark ON work_task_events(status_mark_id) WHERE status_mark_id IS NOT NULL;

CREATE OR REPLACE FUNCTION work_task_events_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM work_tasks WHERE id = OLD.task_id) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'work_task_events is append-only' USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER trg_work_task_events_append_only
    BEFORE UPDATE OR DELETE ON work_task_events
    FOR EACH ROW EXECUTE FUNCTION work_task_events_append_only();

CREATE OR REPLACE FUNCTION work_tasks_keep_history() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF NOT EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'work_tasks are archived, not deleted' USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.id <> OLD.id OR NEW.user_id <> OLD.user_id OR NEW.created_ts <> OLD.created_ts THEN
        RAISE EXCEPTION 'work_tasks identity is immutable' USING ERRCODE = 'restrict_violation';
    END IF;
    IF OLD.deleted_ts IS NOT NULL THEN
        RAISE EXCEPTION 'archived work_tasks are read-only' USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_work_tasks_keep_history
    BEFORE UPDATE OR DELETE ON work_tasks
    FOR EACH ROW EXECUTE FUNCTION work_tasks_keep_history();
