DELETE FROM meal_entries WHERE status_mark_id IN (SELECT id FROM status_marks WHERE is_planned);
UPDATE plan_instances SET status_mark_id = NULL WHERE status_mark_id IN (SELECT id FROM status_marks WHERE is_planned);
DELETE FROM status_marks WHERE is_planned;
DROP INDEX idx_status_marks_planned;
DROP INDEX uq_status_marks_user_start;
ALTER TABLE status_marks DROP COLUMN is_planned;
CREATE UNIQUE INDEX uq_status_marks_user_start ON status_marks(user_id, start_ts);

ALTER TABLE plan_instances ADD COLUMN is_custom BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE plan_instances ADD COLUMN day_id UUID REFERENCES program_days(id) ON DELETE SET NULL;

CREATE TABLE plan_foods (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES plan_events(id) ON DELETE CASCADE,
    occ_date DATE,
    position INT NOT NULL,
    source meal_source_t NOT NULL,
    item_id UUID REFERENCES items(id) ON DELETE CASCADE,
    dish_id UUID REFERENCES dishes(id) ON DELETE CASCADE,
    title VARCHAR(200) CHECK (LENGTH(TRIM(title)) > 0),
    grams NUMERIC(7, 1) CHECK (grams > 0),
    portions NUMERIC(5, 2) CHECK (portions > 0),
    portion_g NUMERIC(7, 1) CHECK (portion_g > 0),
    is_ml BOOLEAN NOT NULL DEFAULT FALSE,
    kcal_100 NUMERIC(7, 2),
    prot_100 NUMERIC(6, 2),
    fat_100 NUMERIC(6, 2),
    carb_100 NUMERIC(6, 2),
    kcal NUMERIC(8, 1) NOT NULL CHECK (kcal >= 0),
    prot NUMERIC(7, 1) NOT NULL CHECK (prot >= 0),
    fat NUMERIC(7, 1) NOT NULL CHECK (fat >= 0),
    carb NUMERIC(7, 1) NOT NULL CHECK (carb >= 0),
    CONSTRAINT plan_foods_source_chk CHECK (
        (source = 'quick' AND grams IS NULL AND portions IS NULL AND kcal_100 IS NULL)
        OR (source <> 'quick' AND title IS NOT NULL AND grams IS NOT NULL AND kcal_100 IS NOT NULL
            AND prot_100 IS NOT NULL AND fat_100 IS NOT NULL AND carb_100 IS NOT NULL)
    )
);
CREATE INDEX idx_plan_foods_event ON plan_foods(event_id, occ_date, position);

CREATE TABLE plan_tasks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES plan_events(id) ON DELETE CASCADE,
    occ_date DATE,
    position INT NOT NULL,
    title VARCHAR(200) NOT NULL CHECK (LENGTH(TRIM(title)) > 0)
);
CREATE INDEX idx_plan_tasks_event ON plan_tasks(event_id, occ_date, position);

CREATE TABLE plan_studies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_id UUID NOT NULL REFERENCES plan_events(id) ON DELETE CASCADE,
    occ_date DATE,
    position INT NOT NULL,
    topic_id UUID NOT NULL REFERENCES study_topics(id) ON DELETE CASCADE,
    note VARCHAR(2000) CHECK (note IS NULL OR LENGTH(TRIM(note)) > 0)
);
CREATE INDEX idx_plan_studies_event ON plan_studies(event_id, occ_date, position);

ALTER TABLE meal_entries ADD COLUMN plan_event_id UUID REFERENCES plan_events(id) ON DELETE SET NULL;
ALTER TABLE meal_entries ADD COLUMN plan_occ_date DATE;
CREATE INDEX idx_meal_entries_plan ON meal_entries(plan_event_id, plan_occ_date) WHERE plan_event_id IS NOT NULL;
ALTER TABLE work_tasks ADD COLUMN plan_event_id UUID;
ALTER TABLE work_tasks ADD COLUMN plan_occ_date DATE;
CREATE INDEX idx_work_tasks_plan ON work_tasks(plan_event_id, plan_occ_date) WHERE plan_event_id IS NOT NULL;
ALTER TABLE study_notes ADD COLUMN plan_event_id UUID REFERENCES plan_events(id) ON DELETE SET NULL;
ALTER TABLE study_notes ADD COLUMN plan_occ_date DATE;
CREATE INDEX idx_study_notes_plan ON study_notes(plan_event_id, plan_occ_date) WHERE plan_event_id IS NOT NULL;
