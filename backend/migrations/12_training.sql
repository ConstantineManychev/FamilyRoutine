CREATE TYPE schedule_mode_t AS ENUM ('queue', 'intervals', 'weekdays');
ALTER TYPE widget_kind_t ADD VALUE IF NOT EXISTS 'next_workout';

ALTER TABLE dict_exs ADD COLUMN code VARCHAR(50);
CREATE UNIQUE INDEX uq_dict_exs_code ON dict_exs(code) WHERE code IS NOT NULL;

CREATE TABLE training_programs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    schedule_mode schedule_mode_t NOT NULL DEFAULT 'queue',
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    anchor_day_id UUID,
    anchor_date DATE,
    anchor_ts TIMESTAMPTZ,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_training_programs_user ON training_programs(user_id);
CREATE UNIQUE INDEX uq_training_programs_active ON training_programs(user_id) WHERE is_active;

CREATE TABLE program_days (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    program_id UUID NOT NULL REFERENCES training_programs(id) ON DELETE CASCADE,
    position INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    rest_days_after INT NOT NULL DEFAULT 1 CHECK (rest_days_after BETWEEN 0 AND 14),
    weekday_mask INT NOT NULL DEFAULT 0 CHECK (weekday_mask BETWEEN 0 AND 127)
);
CREATE INDEX idx_program_days_program ON program_days(program_id, position);

ALTER TABLE training_programs ADD CONSTRAINT training_programs_anchor_fk
    FOREIGN KEY (anchor_day_id) REFERENCES program_days(id) ON DELETE SET NULL;

CREATE TABLE program_exercises (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    day_id UUID NOT NULL REFERENCES program_days(id) ON DELETE CASCADE,
    position INT NOT NULL,
    ex_id UUID NOT NULL REFERENCES dict_exs(id) ON DELETE RESTRICT,
    sets INT NOT NULL CHECK (sets BETWEEN 1 AND 20),
    reps_min INT CHECK (reps_min BETWEEN 1 AND 200),
    reps_max INT CHECK (reps_max BETWEEN 1 AND 200),
    duration_sec INT CHECK (duration_sec BETWEEN 1 AND 7200),
    weight_kg NUMERIC(6, 2) CHECK (weight_kg >= 0 AND weight_kg <= 1000),
    rest_sec INT CHECK (rest_sec BETWEEN 0 AND 900),
    weight_step NUMERIC(5, 2) CHECK (weight_step > 0 AND weight_step <= 50),
    note VARCHAR(200),
    CONSTRAINT program_exercises_reps_chk CHECK (reps_min IS NULL OR reps_max IS NULL OR reps_min <= reps_max)
);
CREATE INDEX idx_program_exercises_day ON program_exercises(day_id, position);

DROP TABLE workout_exs;
DROP TABLE user_workouts;

CREATE TABLE workout_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    program_id UUID REFERENCES training_programs(id) ON DELETE SET NULL,
    day_id UUID REFERENCES program_days(id) ON DELETE SET NULL,
    program_name VARCHAR(100),
    day_name VARCHAR(100),
    started_ts TIMESTAMPTZ NOT NULL,
    finished_ts TIMESTAMPTZ,
    intensity INT CHECK (intensity BETWEEN 1 AND 10),
    kcal NUMERIC(7, 1),
    note VARCHAR(500),
    status_mark_id UUID REFERENCES status_marks(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT workout_sessions_range_chk CHECK (finished_ts IS NULL OR finished_ts > started_ts)
);
CREATE INDEX idx_workout_sessions_user ON workout_sessions(user_id, started_ts DESC);
CREATE UNIQUE INDEX uq_workout_sessions_open ON workout_sessions(user_id) WHERE finished_ts IS NULL;

CREATE TABLE session_exercises (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id UUID NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
    position INT NOT NULL,
    ex_id UUID NOT NULL REFERENCES dict_exs(id) ON DELETE RESTRICT,
    reps_min INT,
    reps_max INT,
    duration_sec INT,
    target_weight NUMERIC(6, 2),
    rest_sec INT,
    UNIQUE (session_id, position)
);

CREATE TABLE session_sets (
    session_exercise_id UUID NOT NULL REFERENCES session_exercises(id) ON DELETE CASCADE,
    set_index INT NOT NULL,
    reps INT CHECK (reps BETWEEN 0 AND 1000),
    weight_kg NUMERIC(6, 2) CHECK (weight_kg >= 0 AND weight_kg <= 1000),
    duration_sec INT CHECK (duration_sec BETWEEN 0 AND 36000),
    is_done BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (session_exercise_id, set_index)
);

WITH seed (code, name, type, met, weight_type, bw_pct, groups) AS (
    VALUES
        ('bench_press', 'Bench press', 'strength', 5.0, 'external', 0, 'chest:60,arms:30,shoulders:10'),
        ('incline_bench_press', 'Incline bench press', 'strength', 5.0, 'external', 0, 'chest:55,shoulders:25,arms:20'),
        ('dumbbell_bench_press', 'Dumbbell bench press', 'strength', 5.0, 'external', 0, 'chest:60,arms:25,shoulders:15'),
        ('chest_fly', 'Chest fly', 'strength', 3.5, 'external', 0, 'chest:90,shoulders:10'),
        ('push_up', 'Push-up', 'strength', 3.8, 'bodyweight', 64, 'chest:60,arms:25,shoulders:15'),
        ('dips', 'Dips', 'strength', 5.0, 'bodyweight', 100, 'chest:40,arms:50,shoulders:10'),
        ('pull_up', 'Pull-up', 'strength', 5.0, 'bodyweight', 100, 'back:70,arms:30'),
        ('lat_pulldown', 'Lat pulldown', 'strength', 5.0, 'external', 0, 'back:70,arms:30'),
        ('barbell_row', 'Barbell row', 'strength', 5.0, 'external', 0, 'back:70,arms:20,core:10'),
        ('dumbbell_row', 'Dumbbell row', 'strength', 5.0, 'external', 0, 'back:70,arms:30'),
        ('seated_cable_row', 'Seated cable row', 'strength', 5.0, 'external', 0, 'back:70,arms:30'),
        ('deadlift', 'Deadlift', 'strength', 6.0, 'hybrid', 50, 'back:40,legs:50,core:10'),
        ('romanian_deadlift', 'Romanian deadlift', 'strength', 6.0, 'hybrid', 50, 'legs:60,back:40'),
        ('back_squat', 'Back squat', 'strength', 6.0, 'hybrid', 85, 'legs:80,core:10,back:10'),
        ('front_squat', 'Front squat', 'strength', 6.0, 'hybrid', 85, 'legs:80,core:20'),
        ('leg_press', 'Leg press', 'strength', 5.0, 'external', 0, 'legs:100'),
        ('lunge', 'Lunges', 'strength', 5.0, 'hybrid', 80, 'legs:90,core:10'),
        ('leg_extension', 'Leg extension', 'strength', 3.5, 'external', 0, 'legs:100'),
        ('leg_curl', 'Leg curl', 'strength', 3.5, 'external', 0, 'legs:100'),
        ('calf_raise', 'Calf raise', 'strength', 3.5, 'hybrid', 90, 'legs:100'),
        ('hip_thrust', 'Hip thrust', 'strength', 5.0, 'hybrid', 50, 'legs:90,core:10'),
        ('overhead_press', 'Overhead press', 'strength', 5.0, 'external', 0, 'shoulders:70,arms:30'),
        ('dumbbell_shoulder_press', 'Dumbbell shoulder press', 'strength', 5.0, 'external', 0, 'shoulders:70,arms:30'),
        ('lateral_raise', 'Lateral raise', 'strength', 3.5, 'external', 0, 'shoulders:100'),
        ('face_pull', 'Face pull', 'strength', 3.5, 'external', 0, 'shoulders:60,back:40'),
        ('biceps_curl', 'Biceps curl', 'strength', 3.5, 'external', 0, 'arms:100'),
        ('hammer_curl', 'Hammer curl', 'strength', 3.5, 'external', 0, 'arms:100'),
        ('triceps_pushdown', 'Triceps pushdown', 'strength', 3.5, 'external', 0, 'arms:100'),
        ('skull_crusher', 'Skull crusher', 'strength', 3.5, 'external', 0, 'arms:100'),
        ('plank', 'Plank', 'strength', 3.8, 'bodyweight', 100, 'core:100'),
        ('crunch', 'Crunches', 'strength', 3.8, 'bodyweight', 30, 'core:100'),
        ('hanging_leg_raise', 'Hanging leg raise', 'strength', 4.0, 'bodyweight', 40, 'core:80,arms:20'),
        ('kettlebell_swing', 'Kettlebell swing', 'mixed', 8.0, 'external', 0, 'legs:40,back:30,core:30'),
        ('burpee', 'Burpees', 'mixed', 8.0, 'bodyweight', 100, 'full_body:100'),
        ('running', 'Running', 'cardio', 9.8, 'bodyweight', 100, 'cardio:100'),
        ('brisk_walking', 'Brisk walking', 'cardio', 4.3, 'bodyweight', 100, 'cardio:100'),
        ('stationary_bike', 'Stationary bike', 'cardio', 6.8, 'external', 0, 'cardio:80,legs:20'),
        ('rowing_machine', 'Rowing machine', 'cardio', 7.0, 'external', 0, 'cardio:70,back:30'),
        ('elliptical', 'Elliptical trainer', 'cardio', 5.0, 'external', 0, 'cardio:100'),
        ('jump_rope', 'Jump rope', 'cardio', 11.0, 'bodyweight', 100, 'cardio:100'),
        ('swimming', 'Swimming', 'cardio', 7.0, 'bodyweight', 0, 'cardio:70,full_body:30'),
        ('stretching', 'Stretching', 'flexibility', 2.3, 'bodyweight', 0, 'full_body:100'),
        ('yoga', 'Yoga', 'flexibility', 2.5, 'bodyweight', 0, 'full_body:100')
),
inserted AS (
    INSERT INTO dict_exs (name, type, met_val, is_custom, weight_type, bw_pct, code)
    SELECT name, type::ex_type_t, met, FALSE, weight_type::weight_t, bw_pct, code FROM seed
    RETURNING id, code
)
INSERT INTO ex_musc_grps (ex_id, grp, pct)
SELECT i.id, split_part(part, ':', 1)::musc_grp_t, split_part(part, ':', 2)::NUMERIC
FROM inserted i
JOIN seed s ON s.code = i.code
CROSS JOIN LATERAL unnest(string_to_array(s.groups, ',')) AS part;
