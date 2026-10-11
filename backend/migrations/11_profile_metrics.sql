CREATE TYPE sex_t AS ENUM ('male', 'female');
CREATE TYPE activity_t AS ENUM ('sedentary', 'light', 'moderate', 'active', 'very_active');
CREATE TYPE body_metric_t AS ENUM (
    'height', 'weight', 'body_fat', 'muscle_mass', 'skeletal_muscle', 'bone_mass', 'body_water', 'protein',
    'visceral_fat', 'neck', 'chest', 'waist', 'hips', 'biceps_left', 'biceps_right', 'forearm_left', 'forearm_right',
    'thigh_left', 'thigh_right', 'calf_left', 'calf_right'
);
CREATE TYPE body_source_t AS ENUM ('manual', 'import');

ALTER TABLE users ADD COLUMN sex sex_t;
UPDATE users SET sex = CASE LOWER(TRIM(gender)) WHEN 'male' THEN 'male'::sex_t WHEN 'female' THEN 'female'::sex_t END;
ALTER TABLE users DROP COLUMN gender;
ALTER TABLE users ADD COLUMN activity activity_t;
ALTER TABLE users ADD COLUMN is_managed BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN managed_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
ALTER TABLE users ALTER COLUMN username DROP NOT NULL;
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;
ALTER TABLE users ADD CONSTRAINT users_login_chk
    CHECK (is_managed = (email IS NULL) AND is_managed = (password_hash IS NULL));

CREATE TABLE body_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    measured_ts TIMESTAMPTZ NOT NULL,
    source body_source_t NOT NULL DEFAULT 'manual',
    note VARCHAR(200),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_body_entries_user_ts ON body_entries(user_id, measured_ts DESC);

CREATE TABLE body_values (
    entry_id UUID NOT NULL REFERENCES body_entries(id) ON DELETE CASCADE,
    metric body_metric_t NOT NULL,
    value NUMERIC(7, 2) NOT NULL CHECK (value > 0),
    PRIMARY KEY (entry_id, metric)
);

INSERT INTO body_entries (id, user_id, measured_ts, created_by)
SELECT id, user_id, rec_ts, user_id FROM body_snaps WHERE user_id IS NOT NULL;

INSERT INTO body_values (entry_id, metric, value)
SELECT s.id, v.metric, v.value
FROM body_snaps s
JOIN body_entries e ON e.id = s.id
CROSS JOIN LATERAL (
    VALUES
        ('weight'::body_metric_t, s.weight),
        ('height'::body_metric_t, s.height),
        ('body_fat'::body_metric_t, s.fat_pct),
        ('muscle_mass'::body_metric_t, ROUND(s.musc_pct * s.weight / 100, 2)),
        ('skeletal_muscle'::body_metric_t, ROUND(s.skel_musc_pct * s.weight / 100, 2))
) AS v(metric, value)
WHERE v.value > 0;

DROP TABLE body_snaps;
DROP TABLE user_meas;

ALTER TABLE family_mems ADD COLUMN is_body_shared BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE family_mems ADD COLUMN is_composition_shared BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE family_mems ADD COLUMN is_measures_shared BOOLEAN NOT NULL DEFAULT TRUE;
