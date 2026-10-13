CREATE TABLE account_shares (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (account_id, family_id)
);
CREATE INDEX idx_account_shares_family ON account_shares(family_id);

CREATE OR REPLACE VIEW account_viewers AS
    SELECT grants.account_id, grants.viewer_id, BOOL_OR(grants.is_editor) AS is_editor
    FROM (
        SELECT a.id AS account_id, a.user_id AS viewer_id, TRUE AS is_editor
        FROM accounts a
        WHERE a.user_id IS NOT NULL
        UNION ALL
        SELECT a.id, fm.user_id, (fm.role = 'admin' OR a.created_by = fm.user_id)
        FROM accounts a
        JOIN family_mems fm ON fm.family_id = a.family_id
        UNION ALL
        SELECT s.account_id, fm.user_id, FALSE
        FROM account_shares s
        JOIN accounts a ON a.id = s.account_id
        JOIN family_mems holder ON holder.family_id = s.family_id AND holder.user_id = a.user_id
        JOIN family_mems fm ON fm.family_id = s.family_id
    ) grants
    GROUP BY grants.account_id, grants.viewer_id;

ALTER TABLE family_mems ADD COLUMN is_training_shared BOOLEAN NOT NULL DEFAULT TRUE;
