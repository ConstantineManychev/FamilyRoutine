ALTER TABLE plan_foods ADD COLUMN cat_id UUID REFERENCES product_cats(id) ON DELETE CASCADE;

ALTER TABLE plan_foods ADD CONSTRAINT plan_foods_cat_chk CHECK (
    cat_id IS NULL OR (source = 'item' AND item_id IS NULL AND dish_id IS NULL AND portions IS NULL)
);

ALTER TABLE plan_foods ADD CONSTRAINT plan_foods_ref_chk CHECK (
    (source = 'item' AND (item_id IS NOT NULL OR cat_id IS NOT NULL))
    OR (source = 'dish' AND dish_id IS NOT NULL)
    OR source = 'quick'
);

CREATE INDEX idx_plan_foods_cat ON plan_foods(cat_id) WHERE cat_id IS NOT NULL;
