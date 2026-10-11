CREATE TYPE ai_provider_t AS ENUM ('anthropic', 'openai', 'gemini');
CREATE TYPE ai_source_t AS ENUM ('off', 'server', 'anthropic', 'openai', 'gemini');

CREATE TABLE user_ai_keys (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider ai_provider_t NOT NULL,
    sealed_key BYTEA NOT NULL,
    key_hint VARCHAR(8) NOT NULL,
    model VARCHAR(100) NOT NULL,
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, provider)
);

CREATE TABLE user_ai_settings (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    source ai_source_t NOT NULL,
    daily_limit INT CHECK (daily_limit BETWEEN 1 AND 1000),
    monthly_limit INT CHECK (monthly_limit BETWEEN 1 AND 30000),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE receipt_scans
    ADD COLUMN is_own_key BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN input_tokens BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN output_tokens BIGINT NOT NULL DEFAULT 0;
ALTER TABLE receipt_scans DROP CONSTRAINT receipt_scans_pkey;
ALTER TABLE receipt_scans ADD PRIMARY KEY (user_id, scan_day, is_own_key);
