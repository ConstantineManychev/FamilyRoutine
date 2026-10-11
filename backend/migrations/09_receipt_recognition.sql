CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE item_aliases (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    alias_key VARCHAR(200) NOT NULL,
    item_id UUID NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, alias_key)
);
CREATE INDEX idx_item_aliases_item ON item_aliases(item_id);

CREATE TABLE receipt_scans (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scan_day DATE NOT NULL,
    scan_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, scan_day)
);

ALTER TABLE place_addrs ALTER COLUMN zip DROP NOT NULL;

CREATE INDEX idx_items_name_trgm ON items USING gin (LOWER(name) gin_trgm_ops);
CREATE INDEX idx_places_name_trgm ON places USING gin (LOWER(name) gin_trgm_ops);
