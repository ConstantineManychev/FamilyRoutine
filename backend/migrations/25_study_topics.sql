CREATE TYPE study_unit_t AS ENUM ('percent', 'pages', 'tasks', 'lessons', 'chapters', 'hours');

CREATE TABLE study_topics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES study_topics(id),
    title VARCHAR(200) NOT NULL CHECK (LENGTH(TRIM(title)) > 0),
    description VARCHAR(2000),
    unit study_unit_t NOT NULL DEFAULT 'percent',
    target NUMERIC(8, 1) NOT NULL DEFAULT 100 CHECK (target > 0 AND target <= 100000),
    done NUMERIC(8, 1) NOT NULL DEFAULT 0 CHECK (done >= 0 AND done <= 100000),
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT study_topics_percent_chk CHECK (unit <> 'percent' OR (target = 100 AND done <= 100)),
    CONSTRAINT study_topics_parent_chk CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE INDEX idx_study_topics_user ON study_topics(user_id);
CREATE INDEX idx_study_topics_parent ON study_topics(parent_id) WHERE parent_id IS NOT NULL;

CREATE TABLE study_notes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    topic_id UUID NOT NULL REFERENCES study_topics(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body VARCHAR(5000) NOT NULL CHECK (LENGTH(TRIM(body)) > 0),
    note_ts TIMESTAMPTZ NOT NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_study_notes_topic ON study_notes(topic_id, note_ts DESC);
CREATE INDEX idx_study_notes_user_ts ON study_notes(user_id, note_ts);
