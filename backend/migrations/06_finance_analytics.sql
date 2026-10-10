ALTER TABLE transactions ADD COLUMN is_category_locked BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE transactions ADD COLUMN is_match_blocked BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE transactions ADD COLUMN is_auto_transfer BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE transactions ADD COLUMN rule_key VARCHAR(100);

CREATE INDEX idx_tx_rule_key ON transactions(rule_key) WHERE rule_key IS NOT NULL;
CREATE INDEX idx_tx_bank_uncategorized ON transactions(id) WHERE source = 'bank' AND rule_key IS NULL;

CREATE TABLE category_rules (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    rule_key VARCHAR(100) NOT NULL,
    category tx_cat_t NOT NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, rule_key)
);

CREATE TABLE fx_rate_days (
    rate_date DATE PRIMARY KEY,
    fetched_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO currencies (code) VALUES ('UAH') ON CONFLICT DO NOTHING;

CREATE INDEX idx_currency_rates_lookup ON currency_rates(base_curr_id, target_curr_id, date DESC);

CREATE FUNCTION uah_rate(a_curr_id UUID, a_date DATE) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN c.code = 'UAH' THEN 1::numeric
        ELSE COALESCE(
            (
                SELECT r.rate FROM currency_rates r
                WHERE r.base_curr_id = u.id AND r.target_curr_id = c.id AND r.date <= a_date
                ORDER BY r.date DESC LIMIT 1
            ),
            (
                SELECT r.rate FROM currency_rates r
                WHERE r.base_curr_id = u.id AND r.target_curr_id = c.id AND r.date > a_date
                ORDER BY r.date ASC LIMIT 1
            )
        )
    END
    FROM currencies c
    CROSS JOIN currencies u
    WHERE c.id = a_curr_id AND u.code = 'UAH'
$$;
