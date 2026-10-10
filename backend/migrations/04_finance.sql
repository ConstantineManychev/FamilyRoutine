CREATE TYPE bank_provider_t AS ENUM ('monobank', 'enable_banking');
CREATE TYPE bank_conn_status_t AS ENUM ('pending', 'active', 'error', 'expired');
CREATE TYPE tx_source_t AS ENUM ('manual', 'bank', 'receipt_cash');
CREATE TYPE tx_cat_t AS ENUM (
    'groceries', 'restaurants', 'transport', 'fuel', 'shopping', 'health', 'utilities', 'entertainment',
    'travel', 'education', 'home', 'cash', 'transfer', 'fees', 'income', 'other'
);

CREATE TABLE bank_conns (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider bank_provider_t NOT NULL,
    aspsp_name VARCHAR(100),
    aspsp_country CHAR(2),
    secret BYTEA,
    state_hash BYTEA UNIQUE,
    status bank_conn_status_t NOT NULL DEFAULT 'pending',
    valid_until TIMESTAMPTZ,
    last_call_ts TIMESTAMPTZ,
    last_sync_ts TIMESTAMPTZ,
    next_sync_ts TIMESTAMPTZ,
    lease_until TIMESTAMPTZ,
    last_error VARCHAR(64),
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT bank_conn_secret_chk CHECK (status = 'pending' OR secret IS NOT NULL)
);
CREATE INDEX idx_bank_conns_owner ON bank_conns(owner_id);
CREATE INDEX idx_bank_conns_due ON bank_conns(next_sync_ts) WHERE status = 'active';

ALTER TABLE accounts DROP CONSTRAINT acc_secret_owner_chk;
ALTER TABLE accounts DROP COLUMN sync_secret;
ALTER TABLE accounts DROP CONSTRAINT accounts_ext_acc_id_key;
ALTER TABLE accounts ADD COLUMN conn_id UUID REFERENCES bank_conns(id) ON DELETE SET NULL;
ALTER TABLE accounts ADD COLUMN balance NUMERIC(15, 2);
ALTER TABLE accounts ADD COLUMN balance_ts TIMESTAMPTZ;
ALTER TABLE accounts ADD COLUMN history_from_ts TIMESTAMPTZ;
ALTER TABLE accounts ADD COLUMN is_history_done BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE accounts ADD CONSTRAINT acc_conn_owner_chk CHECK (conn_id IS NULL OR user_id IS NOT NULL);
CREATE UNIQUE INDEX uq_accounts_conn_ext ON accounts(conn_id, ext_acc_id) WHERE conn_id IS NOT NULL;
CREATE INDEX idx_accounts_user ON accounts(user_id);
CREATE INDEX idx_accounts_family ON accounts(family_id);

CREATE VIEW account_viewers AS
    SELECT a.id AS account_id, a.user_id AS viewer_id, TRUE AS is_editor
    FROM accounts a
    WHERE a.user_id IS NOT NULL
    UNION ALL
    SELECT a.id, fm.user_id, (fm.role = 'admin' OR a.created_by = fm.user_id)
    FROM accounts a
    JOIN family_mems fm ON fm.family_id = a.family_id;

CREATE TABLE merchants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    name_key VARCHAR(100) NOT NULL UNIQUE,
    mcc SMALLINT CHECK (mcc BETWEEN 0 AND 9999),
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE receipts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    receipt_ts TIMESTAMPTZ NOT NULL,
    merchant_id UUID REFERENCES merchants(id) ON DELETE SET NULL,
    merchant_name VARCHAR(100),
    place_id UUID REFERENCES places(id) ON DELETE SET NULL,
    curr_id UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    cash_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    note VARCHAR(500),
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_receipts_owner_ts ON receipts(owner_id, receipt_ts DESC);

CREATE TABLE receipt_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    receipt_id UUID NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
    pos SMALLINT NOT NULL,
    name VARCHAR(200) NOT NULL,
    kind item_t NOT NULL DEFAULT 'product',
    qty NUMERIC(12, 3) NOT NULL DEFAULT 1 CHECK (qty > 0),
    unit_price NUMERIC(15, 2) CHECK (unit_price >= 0),
    amount NUMERIC(15, 2) NOT NULL CHECK (amount >= 0),
    UNIQUE (receipt_id, pos)
);

ALTER TABLE transactions RENAME COLUMN date TO tx_ts;
ALTER TABLE transactions ADD COLUMN ext_id VARCHAR(128);
ALTER TABLE transactions ADD COLUMN source tx_source_t NOT NULL DEFAULT 'manual';
ALTER TABLE transactions ADD COLUMN description VARCHAR(500);
ALTER TABLE transactions ADD COLUMN counterparty VARCHAR(200);
ALTER TABLE transactions ADD COLUMN mcc SMALLINT CHECK (mcc BETWEEN 0 AND 9999);
ALTER TABLE transactions ADD COLUMN category tx_cat_t;
ALTER TABLE transactions ADD COLUMN merchant_id UUID REFERENCES merchants(id) ON DELETE SET NULL;
ALTER TABLE transactions ADD COLUMN op_amount NUMERIC(15, 2);
ALTER TABLE transactions ADD COLUMN op_curr_id UUID REFERENCES currencies(id) ON DELETE RESTRICT;
ALTER TABLE transactions ADD COLUMN balance_after NUMERIC(15, 2);
ALTER TABLE transactions ADD COLUMN is_pending BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE transactions ADD COLUMN transfer_id UUID;
ALTER TABLE transactions ADD COLUMN receipt_id UUID REFERENCES receipts(id) ON DELETE SET NULL;
ALTER TABLE transactions ADD COLUMN note VARCHAR(500);
ALTER TABLE transactions ADD COLUMN created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE transactions ADD CONSTRAINT tx_amount_nonzero_chk CHECK (amount <> 0);
ALTER TABLE transactions ADD CONSTRAINT tx_bank_ext_chk CHECK (source <> 'bank' OR ext_id IS NOT NULL);
ALTER TABLE transactions ADD CONSTRAINT tx_receipt_cash_chk CHECK (source <> 'receipt_cash' OR receipt_id IS NOT NULL);
DROP INDEX idx_transactions_account_date;
DROP INDEX idx_transactions_user_date;
CREATE UNIQUE INDEX uq_tx_account_ext ON transactions(account_id, ext_id) WHERE ext_id IS NOT NULL;
CREATE UNIQUE INDEX uq_tx_receipt_cash ON transactions(receipt_id) WHERE source = 'receipt_cash';
CREATE INDEX idx_tx_account_ts ON transactions(account_id, tx_ts DESC, id DESC);
CREATE INDEX idx_tx_transfer ON transactions(transfer_id) WHERE transfer_id IS NOT NULL;
CREATE INDEX idx_tx_receipt ON transactions(receipt_id) WHERE receipt_id IS NOT NULL;
CREATE INDEX idx_tx_merchant ON transactions(merchant_id) WHERE merchant_id IS NOT NULL;

INSERT INTO currencies (code) VALUES ('CHF'), ('CZK'), ('HUF'), ('SEK'), ('NOK'), ('DKK'), ('TRY'), ('JPY'), ('CNY'), ('CAD')
ON CONFLICT DO NOTHING;
