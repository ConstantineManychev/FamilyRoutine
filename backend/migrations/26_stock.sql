CREATE TYPE stock_measure_t AS ENUM ('g', 'ml', 'pcs');
CREATE TYPE stock_kind_t AS ENUM ('item', 'dish');
CREATE TYPE stock_source_t AS ENUM ('receipt', 'manual', 'cooked');
CREATE TYPE stock_move_t AS ENUM ('eaten', 'cooked', 'waste');
CREATE TYPE waste_reason_t AS ENUM ('spoiled', 'leftovers', 'other');

CREATE TABLE stock_settings (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    family_id UUID REFERENCES families(id) ON DELETE SET NULL,
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE cook_batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID REFERENCES users(id) ON DELETE CASCADE,
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    dish_id UUID REFERENCES dishes(id) ON DELETE SET NULL,
    title VARCHAR(100) NOT NULL CHECK (LENGTH(TRIM(title)) > 0),
    cooked_by UUID REFERENCES users(id) ON DELETE SET NULL,
    cooked_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    raw_g NUMERIC(9, 1) NOT NULL CHECK (raw_g > 0),
    cooked_g NUMERIC(9, 1) NOT NULL CHECK (cooked_g > 0 AND cooked_g <= 100000),
    kcal_100 NUMERIC(7, 2) NOT NULL CHECK (kcal_100 >= 0),
    prot_100 NUMERIC(6, 2) NOT NULL CHECK (prot_100 >= 0),
    fat_100 NUMERIC(6, 2) NOT NULL CHECK (fat_100 >= 0),
    carb_100 NUMERIC(6, 2) NOT NULL CHECK (carb_100 >= 0),
    missing_count INT NOT NULL DEFAULT 0 CHECK (missing_count >= 0),
    note VARCHAR(500),
    CONSTRAINT cook_batches_store_chk CHECK ((owner_id IS NULL) <> (family_id IS NULL))
);

CREATE INDEX idx_cook_batches_dish ON cook_batches(dish_id) WHERE dish_id IS NOT NULL;

CREATE TABLE cook_batch_items (
    batch_id UUID NOT NULL REFERENCES cook_batches(id) ON DELETE CASCADE,
    position SMALLINT NOT NULL CHECK (position >= 0),
    item_id UUID REFERENCES items(id) ON DELETE SET NULL,
    item_name VARCHAR(255) NOT NULL,
    grams NUMERIC(8, 1) NOT NULL CHECK (grams > 0),
    short_g NUMERIC(8, 1) NOT NULL DEFAULT 0 CHECK (short_g >= 0 AND short_g <= grams),
    PRIMARY KEY (batch_id, position)
);

CREATE INDEX idx_cook_batch_items_item ON cook_batch_items(item_id) WHERE item_id IS NOT NULL;

CREATE TABLE stock_lots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID REFERENCES users(id) ON DELETE CASCADE,
    family_id UUID REFERENCES families(id) ON DELETE CASCADE,
    kind stock_kind_t NOT NULL,
    item_id UUID REFERENCES items(id) ON DELETE SET NULL,
    batch_id UUID UNIQUE REFERENCES cook_batches(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL CHECK (LENGTH(TRIM(title)) > 0),
    measure stock_measure_t NOT NULL,
    qty NUMERIC(10, 1) NOT NULL CHECK (qty > 0 AND qty <= 1000000),
    cost NUMERIC(15, 2) CHECK (cost >= 0),
    curr_id UUID REFERENCES currencies(id) ON DELETE RESTRICT,
    source stock_source_t NOT NULL,
    receipt_id UUID REFERENCES receipts(id) ON DELETE SET NULL,
    receipt_pos SMALLINT CHECK (receipt_pos >= 0),
    added_by UUID REFERENCES users(id) ON DELETE SET NULL,
    acquired_ts TIMESTAMPTZ NOT NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT stock_lots_store_chk CHECK ((owner_id IS NULL) <> (family_id IS NULL)),
    CONSTRAINT stock_lots_cost_chk CHECK ((cost IS NULL) = (curr_id IS NULL)),
    CONSTRAINT stock_lots_kind_chk CHECK ((kind = 'dish') = (batch_id IS NOT NULL) AND (kind = 'dish') = (source = 'cooked')),
    CONSTRAINT stock_lots_receipt_chk CHECK (receipt_pos IS NULL OR (receipt_id IS NOT NULL AND source = 'receipt'))
);

CREATE INDEX idx_stock_lots_owner ON stock_lots(owner_id, item_id) WHERE owner_id IS NOT NULL;
CREATE INDEX idx_stock_lots_family ON stock_lots(family_id, item_id) WHERE family_id IS NOT NULL;
CREATE INDEX idx_stock_lots_item ON stock_lots(item_id) WHERE item_id IS NOT NULL;
CREATE UNIQUE INDEX uq_stock_lots_receipt_pos ON stock_lots(receipt_id, receipt_pos) WHERE receipt_pos IS NOT NULL;

ALTER TABLE meal_entries ADD COLUMN batch_id UUID REFERENCES cook_batches(id) ON DELETE SET NULL;
ALTER TABLE meal_entries ADD COLUMN stock_short NUMERIC(7, 1) CHECK (stock_short >= 0);

CREATE INDEX idx_meal_entries_batch ON meal_entries(batch_id) WHERE batch_id IS NOT NULL;

CREATE TABLE stock_moves (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    lot_id UUID NOT NULL REFERENCES stock_lots(id) ON DELETE CASCADE,
    kind stock_move_t NOT NULL,
    qty NUMERIC(10, 1) NOT NULL CHECK (qty > 0),
    cost NUMERIC(15, 2) CHECK (cost >= 0),
    meal_entry_id UUID REFERENCES meal_entries(id) ON DELETE CASCADE,
    batch_id UUID REFERENCES cook_batches(id) ON DELETE CASCADE,
    reason waste_reason_t,
    note VARCHAR(500),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT stock_moves_eaten_chk CHECK ((kind = 'eaten') = (meal_entry_id IS NOT NULL)),
    CONSTRAINT stock_moves_cooked_chk CHECK ((kind = 'cooked') = (batch_id IS NOT NULL)),
    CONSTRAINT stock_moves_waste_chk CHECK ((kind = 'waste') = (reason IS NOT NULL))
);

CREATE INDEX idx_stock_moves_lot ON stock_moves(lot_id);
CREATE INDEX idx_stock_moves_entry ON stock_moves(meal_entry_id) WHERE meal_entry_id IS NOT NULL;
CREATE INDEX idx_stock_moves_batch ON stock_moves(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX idx_stock_moves_waste ON stock_moves(created_ts) WHERE kind = 'waste';

ALTER TABLE receipts ADD COLUMN is_stocked BOOLEAN NOT NULL DEFAULT TRUE;

CREATE OR REPLACE FUNCTION item_used_by_others(a_item_id UUID, a_user_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id
        WHERE ri.item_id = a_item_id AND r.owner_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM item_prices ip
        WHERE ip.item_id = a_item_id AND ip.owner_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM dish_ingredients di JOIN dishes d ON d.id = di.dish_id
        WHERE di.item_id = a_item_id AND d.owner_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM meal_entries me
        WHERE me.item_id = a_item_id AND me.user_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM stock_lots sl
        WHERE sl.item_id = a_item_id AND sl.owner_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM cook_batch_items cbi JOIN cook_batches cb ON cb.id = cbi.batch_id
        WHERE cbi.item_id = a_item_id AND cb.owner_id IS DISTINCT FROM a_user_id
    )
$$;
