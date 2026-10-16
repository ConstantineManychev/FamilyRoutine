ALTER TABLE family_mems ADD COLUMN is_meals_shared BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE meal_entries ADD COLUMN status_mark_id UUID REFERENCES status_marks(id) ON DELETE SET NULL;

CREATE INDEX idx_meal_entries_mark ON meal_entries(status_mark_id) WHERE status_mark_id IS NOT NULL;
CREATE INDEX idx_workout_sessions_mark ON workout_sessions(status_mark_id) WHERE status_mark_id IS NOT NULL;
