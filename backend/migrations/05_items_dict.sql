CREATE TYPE item_unit_t AS ENUM ('piece', 'kilogram', 'liter', 'meter', 'square_meter', 'hour');

ALTER TABLE items ADD COLUMN owner_id UUID REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE items ADD COLUMN unit item_unit_t NOT NULL DEFAULT 'piece';
ALTER TABLE items ADD COLUMN created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();

INSERT INTO items (owner_id, name, type)
SELECT DISTINCT ON (r.owner_id, LOWER(ri.name)) r.owner_id, ri.name, ri.kind
FROM receipt_items ri
JOIN receipts r ON r.id = ri.receipt_id
ORDER BY r.owner_id, LOWER(ri.name), ri.name;

ALTER TABLE receipt_items ADD COLUMN item_id UUID REFERENCES items(id);

UPDATE receipt_items ri
SET item_id = i.id
FROM receipts r, items i
WHERE r.id = ri.receipt_id AND i.owner_id = r.owner_id AND LOWER(i.name) = LOWER(ri.name);

ALTER TABLE receipt_items ALTER COLUMN item_id SET NOT NULL;
ALTER TABLE receipt_items DROP COLUMN name;
ALTER TABLE receipt_items DROP COLUMN kind;

CREATE UNIQUE INDEX uq_items_owner_name ON items(owner_id, LOWER(name)) WHERE owner_id IS NOT NULL;
CREATE INDEX idx_items_owner ON items(owner_id);
CREATE INDEX idx_receipt_items_item ON receipt_items(item_id);
