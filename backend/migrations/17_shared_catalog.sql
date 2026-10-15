ALTER TABLE items DROP CONSTRAINT items_scope_chk;
DROP INDEX uq_items_family_name;
DROP INDEX uq_items_family_barcode;
DROP INDEX uq_items_owner_barcode;
DROP INDEX uq_items_owner_name;
DROP INDEX idx_items_family;
DROP INDEX idx_items_barcode;

UPDATE items SET owner_id = created_by WHERE family_id IS NOT NULL;
ALTER TABLE items DROP COLUMN family_id;

WITH ranked AS (
    SELECT
        i.id,
        ROW_NUMBER() OVER (
            PARTITION BY i.barcode
            ORDER BY (i.owner_id IS NULL) DESC,
                     (SELECT COUNT(*) FROM receipt_items ri WHERE ri.item_id = i.id) DESC,
                     i.created_ts,
                     i.id
        ) AS position
    FROM items i
    WHERE i.barcode IS NOT NULL
)
UPDATE items i
SET barcode = NULL
FROM ranked r
WHERE i.id = r.id AND r.position > 1;

CREATE UNIQUE INDEX uq_items_barcode ON items(barcode) WHERE barcode IS NOT NULL;
CREATE INDEX idx_items_lower_name ON items(LOWER(name));

ALTER TABLE items DROP CONSTRAINT items_owner_id_fkey;
ALTER TABLE items
    ADD CONSTRAINT items_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE items
    ADD COLUMN kcal NUMERIC(6, 2) CHECK (kcal BETWEEN 0 AND 1000),
    ADD COLUMN prot NUMERIC(5, 2) CHECK (prot BETWEEN 0 AND 100),
    ADD COLUMN fat NUMERIC(5, 2) CHECK (fat BETWEEN 0 AND 100),
    ADD COLUMN carb NUMERIC(5, 2) CHECK (carb BETWEEN 0 AND 100);

UPDATE items i
SET kcal = LEAST(GREATEST(n.kcal, 0), 1000),
    prot = LEAST(GREATEST(n.prot, 0), 100),
    fat = LEAST(GREATEST(n.fat, 0), 100),
    carb = LEAST(GREATEST(n.carb, 0), 100)
FROM food_nutr n
WHERE n.item_id = i.id;
DROP TABLE food_nutr;

CREATE TABLE off_products (
    barcode VARCHAR(14) PRIMARY KEY CHECK (barcode ~ '^[0-9]{8,14}$'),
    product JSONB,
    fetched_ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE FUNCTION item_used_by_others(a_item_id UUID, a_user_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM receipt_items ri JOIN receipts r ON r.id = ri.receipt_id
        WHERE ri.item_id = a_item_id AND r.owner_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM item_prices ip
        WHERE ip.item_id = a_item_id AND ip.owner_id IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM meal_items mi JOIN user_meals um ON um.id = mi.meal_id
        WHERE mi.item_id = a_item_id AND um.user_id IS DISTINCT FROM a_user_id
    )
$$;
