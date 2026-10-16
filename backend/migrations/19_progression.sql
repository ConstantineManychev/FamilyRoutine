CREATE TYPE progression_t AS ENUM ('increase_weight', 'add_reps', 'deload', 'add_time', 'bodyweight_top', 'hold');

ALTER TABLE session_exercises
    ADD COLUMN advice progression_t,
    ADD COLUMN advice_from NUMERIC(8, 2),
    ADD COLUMN advice_to NUMERIC(8, 2);

CREATE INDEX idx_session_exercises_ex ON session_exercises(ex_id, session_id);
