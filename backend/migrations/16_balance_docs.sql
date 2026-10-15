DROP TABLE IF EXISTS acc_snaps;

CREATE TABLE balance_docs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    balance_ts TIMESTAMPTZ NOT NULL,
    amount NUMERIC(15, 2) NOT NULL,
    note VARCHAR(500),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_balance_docs_account_ts UNIQUE (account_id, balance_ts)
);

ALTER TABLE transactions ADD COLUMN balance_doc_id UUID REFERENCES balance_docs(id) ON DELETE CASCADE;
CREATE INDEX idx_tx_balance_doc ON transactions(balance_doc_id) WHERE balance_doc_id IS NOT NULL;

CREATE FUNCTION wallet_balance(a_account_id UUID) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT anchor.amount + COALESCE((
        SELECT SUM(t.amount)
        FROM transactions t
        WHERE t.account_id = a_account_id
          AND NOT t.is_pending
          AND (anchor.anchor_ts IS NULL OR t.tx_ts > anchor.anchor_ts)
    ), 0)
    FROM (
        SELECT d.amount, d.balance_ts AS anchor_ts
        FROM balance_docs d
        WHERE d.account_id = a_account_id
        UNION ALL
        SELECT a.balance, a.balance_ts
        FROM accounts a
        WHERE a.id = a_account_id AND a.balance IS NOT NULL AND a.balance_ts IS NOT NULL
        UNION ALL
        SELECT 0, NULL
        ORDER BY anchor_ts DESC NULLS LAST
        LIMIT 1
    ) anchor
$$;
