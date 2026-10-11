ALTER TABLE items ADD COLUMN barcode VARCHAR(14) CHECK (barcode ~ '^[0-9]{8,14}$');
ALTER TABLE items ADD COLUMN family_id UUID REFERENCES families(id) ON DELETE RESTRICT;
ALTER TABLE items ADD COLUMN created_by UUID REFERENCES users(id) ON DELETE SET NULL;
UPDATE items SET created_by = owner_id;
ALTER TABLE items ADD CONSTRAINT items_scope_chk CHECK (owner_id IS NULL OR family_id IS NULL);

CREATE UNIQUE INDEX uq_items_family_name ON items(family_id, LOWER(name)) WHERE family_id IS NOT NULL;
CREATE UNIQUE INDEX uq_items_owner_barcode ON items(owner_id, barcode) WHERE owner_id IS NOT NULL AND barcode IS NOT NULL;
CREATE UNIQUE INDEX uq_items_family_barcode ON items(family_id, barcode) WHERE family_id IS NOT NULL AND barcode IS NOT NULL;
CREATE INDEX idx_items_family ON items(family_id) WHERE family_id IS NOT NULL;
CREATE INDEX idx_items_barcode ON items(barcode) WHERE barcode IS NOT NULL;

ALTER TABLE places ADD COLUMN family_id UUID REFERENCES families(id) ON DELETE RESTRICT;
ALTER TABLE places ADD COLUMN created_by UUID REFERENCES users(id) ON DELETE SET NULL;
UPDATE places SET created_by = owner_id;
ALTER TABLE places ADD CONSTRAINT places_scope_chk CHECK (owner_id IS NULL OR family_id IS NULL);
CREATE INDEX idx_places_family ON places(family_id) WHERE family_id IS NOT NULL;

ALTER TABLE receipts ADD COLUMN place_addr_id UUID REFERENCES place_addrs(id) ON DELETE SET NULL;

ALTER TABLE family_mems ADD COLUMN is_prices_shared BOOLEAN NOT NULL DEFAULT FALSE;

CREATE FUNCTION can_see_scoped(a_owner_id UUID, a_family_id UUID, a_user_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN a_family_id IS NOT NULL THEN EXISTS (
            SELECT 1 FROM family_mems WHERE family_id = a_family_id AND user_id = a_user_id
        )
        ELSE COALESCE(a_owner_id = a_user_id, FALSE)
    END
$$;

CREATE FUNCTION can_edit_scoped(a_owner_id UUID, a_family_id UUID, a_created_by UUID, a_user_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN a_family_id IS NOT NULL THEN EXISTS (
            SELECT 1 FROM family_mems
            WHERE family_id = a_family_id AND user_id = a_user_id AND (role = 'admin' OR user_id = a_created_by)
        )
        ELSE COALESCE(a_owner_id = a_user_id, FALSE)
    END
$$;

DROP TABLE item_prices;

CREATE TABLE item_prices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id UUID NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    place_id UUID REFERENCES places(id) ON DELETE SET NULL,
    place_addr_id UUID REFERENCES place_addrs(id) ON DELETE SET NULL,
    merchant_name VARCHAR(100),
    curr_id UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    qty NUMERIC(12, 3) NOT NULL DEFAULT 1 CHECK (qty > 0),
    price NUMERIC(15, 2) NOT NULL CHECK (price >= 0),
    seen_ts TIMESTAMPTZ NOT NULL,
    note VARCHAR(200),
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_item_prices_item ON item_prices(item_id, seen_ts DESC);
CREATE INDEX idx_item_prices_owner ON item_prices(owner_id);
