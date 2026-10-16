CREATE TYPE net_measure_t AS ENUM ('g', 'ml');

CREATE TABLE product_cats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    parent_id UUID REFERENCES product_cats(id) ON DELETE RESTRICT,
    code VARCHAR(40) UNIQUE,
    name VARCHAR(100) NOT NULL CHECK (LENGTH(TRIM(name)) > 0),
    owner_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT product_cats_parent_chk CHECK (parent_id IS DISTINCT FROM id)
);

CREATE UNIQUE INDEX uq_product_cats_sibling
    ON product_cats (COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), LOWER(name));
CREATE INDEX idx_product_cats_parent ON product_cats(parent_id);
CREATE INDEX idx_product_cats_owner ON product_cats(owner_id);

ALTER TABLE items
    ADD COLUMN cat_id UUID REFERENCES product_cats(id) ON DELETE SET NULL,
    ADD COLUMN net_qty NUMERIC(9, 1) CHECK (net_qty > 0 AND net_qty <= 1000000),
    ADD COLUMN net_measure net_measure_t,
    ADD CONSTRAINT items_net_chk CHECK ((net_qty IS NULL) = (net_measure IS NULL));

CREATE INDEX idx_items_cat ON items(cat_id) WHERE cat_id IS NOT NULL;

WITH seed(code, parent_code, name) AS (
    VALUES
        ('dairy', NULL, 'Dairy'),
        ('meat', NULL, 'Meat'),
        ('fish', NULL, 'Fish and seafood'),
        ('eggs', NULL, 'Eggs'),
        ('bakery', NULL, 'Bread and bakery'),
        ('grains', NULL, 'Grains and pasta'),
        ('vegetables', NULL, 'Vegetables and greens'),
        ('fruits', NULL, 'Fruit and berries'),
        ('nuts', NULL, 'Nuts and seeds'),
        ('sweets', NULL, 'Sweets'),
        ('drinks', NULL, 'Drinks'),
        ('grocery', NULL, 'Pantry staples'),
        ('frozen', NULL, 'Frozen food'),
        ('household', NULL, 'Household'),
        ('hygiene', NULL, 'Personal care'),
        ('dairy_milk', 'dairy', 'Milk'),
        ('dairy_kefir', 'dairy', 'Kefir and fermented milk'),
        ('dairy_yogurt', 'dairy', 'Yogurt'),
        ('dairy_cottage', 'dairy', 'Cottage cheese'),
        ('dairy_cream', 'dairy', 'Sour cream and cream'),
        ('dairy_cheese', 'dairy', 'Cheese'),
        ('dairy_butter', 'dairy', 'Butter'),
        ('meat_pork', 'meat', 'Pork'),
        ('meat_beef', 'meat', 'Beef'),
        ('meat_poultry', 'meat', 'Poultry'),
        ('meat_lamb', 'meat', 'Lamb'),
        ('meat_minced', 'meat', 'Minced meat'),
        ('meat_sausages', 'meat', 'Sausages'),
        ('fish_fish', 'fish', 'Fish'),
        ('fish_seafood', 'fish', 'Seafood'),
        ('fish_canned', 'fish', 'Canned fish'),
        ('bakery_bread', 'bakery', 'Bread'),
        ('bakery_pastry', 'bakery', 'Pastry'),
        ('bakery_crispbread', 'bakery', 'Crispbread'),
        ('grains_buckwheat', 'grains', 'Buckwheat'),
        ('grains_rice', 'grains', 'Rice'),
        ('grains_oats', 'grains', 'Oats'),
        ('grains_pasta', 'grains', 'Pasta'),
        ('grains_flour', 'grains', 'Flour'),
        ('grains_other', 'grains', 'Other grains'),
        ('vegetables_fresh', 'vegetables', 'Vegetables'),
        ('vegetables_greens', 'vegetables', 'Greens'),
        ('vegetables_mushrooms', 'vegetables', 'Mushrooms'),
        ('fruits_fruit', 'fruits', 'Fruit'),
        ('fruits_berries', 'fruits', 'Berries'),
        ('fruits_dried', 'fruits', 'Dried fruit'),
        ('sweets_chocolate', 'sweets', 'Chocolate'),
        ('sweets_candy', 'sweets', 'Candy'),
        ('sweets_cookies', 'sweets', 'Cookies'),
        ('drinks_water', 'drinks', 'Water'),
        ('drinks_juice', 'drinks', 'Juice'),
        ('drinks_soda', 'drinks', 'Soft drinks'),
        ('drinks_energy', 'drinks', 'Energy drinks'),
        ('drinks_coffee', 'drinks', 'Coffee'),
        ('drinks_tea', 'drinks', 'Tea'),
        ('drinks_alcohol', 'drinks', 'Alcohol'),
        ('grocery_oil', 'grocery', 'Cooking oil'),
        ('grocery_sugar', 'grocery', 'Sugar and salt'),
        ('grocery_spices', 'grocery', 'Spices'),
        ('grocery_sauces', 'grocery', 'Sauces'),
        ('grocery_canned', 'grocery', 'Canned food'),
        ('frozen_dumplings', 'frozen', 'Dumplings'),
        ('frozen_vegetables', 'frozen', 'Frozen vegetables'),
        ('frozen_icecream', 'frozen', 'Ice cream')
),
roots AS (
    INSERT INTO product_cats (code, name)
    SELECT code, name FROM seed WHERE parent_code IS NULL
    RETURNING id, code
)
INSERT INTO product_cats (parent_id, code, name)
SELECT roots.id, seed.code, seed.name
FROM seed
JOIN roots ON roots.code = seed.parent_code;
