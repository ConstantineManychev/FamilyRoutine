CREATE TABLE sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash BYTEA NOT NULL UNIQUE,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_ts TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_ts);

ALTER TABLE users ADD COLUMN is_pwd_peppered BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE users SET email = LOWER(TRIM(email)), username = LOWER(TRIM(username));

ALTER TABLE accounts DROP COLUMN sync_credentials;
ALTER TABLE accounts ADD COLUMN sync_secret BYTEA;
ALTER TABLE accounts ADD COLUMN created_by UUID REFERENCES users(id) ON DELETE SET NULL;
UPDATE accounts SET created_by = user_id WHERE user_id IS NOT NULL;
UPDATE accounts SET mask = NULLIF(RIGHT(REGEXP_REPLACE(mask, '[^0-9]', '', 'g'), 4), '');
UPDATE accounts SET mask = NULL WHERE mask IS NOT NULL AND mask !~ '^[0-9]{4}$';
ALTER TABLE accounts ADD CONSTRAINT acc_mask_chk CHECK (mask IS NULL OR mask ~ '^[0-9]{4}$');
ALTER TABLE accounts ADD CONSTRAINT acc_secret_owner_chk CHECK (sync_secret IS NULL OR user_id IS NOT NULL);
ALTER TABLE accounts ADD CONSTRAINT acc_name_len_chk CHECK (char_length(name) BETWEEN 1 AND 100);

ALTER TABLE transactions DROP CONSTRAINT transactions_account_id_fkey;
ALTER TABLE transactions ADD CONSTRAINT transactions_account_id_fkey
    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE;
ALTER TABLE transactions DROP CONSTRAINT transactions_user_id_fkey;
ALTER TABLE transactions ADD CONSTRAINT transactions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE places ADD COLUMN owner_id UUID REFERENCES users(id) ON DELETE CASCADE;
CREATE INDEX idx_places_owner ON places(owner_id);
CREATE INDEX idx_place_addrs_place ON place_addrs(place_id);

ALTER TABLE cities ADD COLUMN created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE streets ADD COLUMN created_by UUID REFERENCES users(id) ON DELETE SET NULL;

CREATE TYPE weight_t AS ENUM ('external', 'hybrid', 'bodyweight');
ALTER TABLE dict_exs ADD COLUMN weight_type weight_t NOT NULL DEFAULT 'external';
ALTER TABLE dict_exs ADD COLUMN bw_pct NUMERIC(5, 2) NOT NULL DEFAULT 0;
ALTER TABLE dict_exs ADD CONSTRAINT dict_exs_bw_pct_chk CHECK (bw_pct >= 0 AND bw_pct <= 100);
ALTER TABLE dict_exs DROP CONSTRAINT dict_exs_name_key;
ALTER TABLE dict_exs DROP CONSTRAINT dict_exs_created_by_fkey;
DELETE FROM dict_exs WHERE is_custom = TRUE AND created_by IS NULL;
ALTER TABLE dict_exs ADD CONSTRAINT dict_exs_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE dict_exs ADD CONSTRAINT dict_exs_owner_chk CHECK (is_custom = (created_by IS NOT NULL));
CREATE UNIQUE INDEX uq_dict_exs_sys_name ON dict_exs(LOWER(name)) WHERE is_custom = FALSE;
CREATE UNIQUE INDEX uq_dict_exs_user_name ON dict_exs(created_by, LOWER(name)) WHERE is_custom = TRUE;
CREATE INDEX idx_ex_musc_grps_ex ON ex_musc_grps(ex_id);

CREATE TABLE family_invites (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    code_hash BYTEA NOT NULL UNIQUE,
    role mem_role_t NOT NULL DEFAULT 'standard',
    label VARCHAR(100),
    invited_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_ts TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_family_invites_family ON family_invites(family_id);

CREATE INDEX idx_family_mems_user ON family_mems(user_id);
