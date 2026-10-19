ALTER TYPE stock_move_t ADD VALUE IF NOT EXISTS 'used';

ALTER TABLE stock_lots ADD COLUMN pack_size NUMERIC(10, 1) CHECK (pack_size > 0);

UPDATE stock_lots l
SET pack_size = ROUND(l.qty / ri.qty, 1)
FROM receipt_items ri
JOIN items i ON i.id = ri.item_id
WHERE ri.receipt_id = l.receipt_id AND ri.pos = l.receipt_pos
  AND i.unit = 'piece' AND l.measure IN ('g', 'ml') AND ri.qty > 0 AND ROUND(l.qty / ri.qty, 1) > 0;

ALTER TABLE receipts ADD COLUMN stock_family_id UUID REFERENCES families(id) ON DELETE SET NULL;

UPDATE receipts r
SET stock_family_id = first_lot.family_id
FROM (
    SELECT DISTINCT ON (receipt_id) receipt_id, family_id
    FROM stock_lots
    WHERE receipt_id IS NOT NULL
    ORDER BY receipt_id, created_ts
) first_lot
WHERE first_lot.receipt_id = r.id;

DELETE FROM stock_lots l
USING items i
WHERE i.id = l.item_id AND l.kind = 'item' AND l.source = 'receipt' AND i.type <> 'food'
  AND NOT EXISTS (SELECT 1 FROM stock_moves m WHERE m.lot_id = l.id);

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
        WHERE sl.item_id = a_item_id AND COALESCE(sl.added_by, sl.owner_id) IS DISTINCT FROM a_user_id
    ) OR EXISTS (
        SELECT 1 FROM cook_batch_items cbi JOIN cook_batches cb ON cb.id = cbi.batch_id
        WHERE cbi.item_id = a_item_id AND COALESCE(cb.cooked_by, cb.owner_id) IS DISTINCT FROM a_user_id
    )
$$;
