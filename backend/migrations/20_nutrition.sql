ALTER TABLE items ADD COLUMN piece_g NUMERIC(7, 1) CHECK (piece_g > 0 AND piece_g <= 10000);

CREATE TABLE dishes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL CHECK (LENGTH(TRIM(name)) > 0),
    note VARCHAR(500),
    cooked_g NUMERIC(8, 1) CHECK (cooked_g > 0),
    serving_g NUMERIC(7, 1) CHECK (serving_g > 0),
    servings INT CHECK (servings BETWEEN 1 AND 100),
    is_shared BOOLEAN NOT NULL DEFAULT FALSE,
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT dishes_portion_chk CHECK (serving_g IS NULL OR servings IS NULL)
);

CREATE UNIQUE INDEX uq_dishes_owner_name ON dishes(owner_id, LOWER(name));

CREATE TABLE dish_ingredients (
    dish_id UUID NOT NULL REFERENCES dishes(id) ON DELETE CASCADE,
    position SMALLINT NOT NULL CHECK (position >= 0),
    item_id UUID NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
    grams NUMERIC(8, 1) NOT NULL CHECK (grams > 0),
    PRIMARY KEY (dish_id, position)
);

CREATE INDEX idx_dish_ingredients_item ON dish_ingredients(item_id);

CREATE TYPE meal_source_t AS ENUM ('item', 'dish', 'quick');

CREATE TABLE meal_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    eaten_on DATE NOT NULL,
    meal meal_t NOT NULL,
    source meal_source_t NOT NULL,
    item_id UUID REFERENCES items(id) ON DELETE SET NULL,
    dish_id UUID REFERENCES dishes(id) ON DELETE SET NULL,
    title VARCHAR(200) CHECK (LENGTH(TRIM(title)) > 0),
    grams NUMERIC(7, 1) CHECK (grams > 0),
    portions NUMERIC(5, 2) CHECK (portions > 0),
    portion_g NUMERIC(7, 1) CHECK (portion_g > 0),
    is_ml BOOLEAN NOT NULL DEFAULT FALSE,
    kcal_100 NUMERIC(7, 2),
    prot_100 NUMERIC(6, 2),
    fat_100 NUMERIC(6, 2),
    carb_100 NUMERIC(6, 2),
    kcal NUMERIC(8, 1) NOT NULL CHECK (kcal >= 0),
    prot NUMERIC(7, 1) NOT NULL CHECK (prot >= 0),
    fat NUMERIC(7, 1) NOT NULL CHECK (fat >= 0),
    carb NUMERIC(7, 1) NOT NULL CHECK (carb >= 0),
    created_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT meal_entries_source_chk CHECK (
        (source = 'quick' AND grams IS NULL AND portions IS NULL AND kcal_100 IS NULL)
        OR (source <> 'quick' AND title IS NOT NULL AND grams IS NOT NULL AND kcal_100 IS NOT NULL
            AND prot_100 IS NOT NULL AND fat_100 IS NOT NULL AND carb_100 IS NOT NULL)
    ),
    CONSTRAINT meal_entries_portion_chk CHECK (portions IS NULL OR portion_g IS NOT NULL)
);

CREATE INDEX idx_meal_entries_day ON meal_entries(user_id, eaten_on);
CREATE INDEX idx_meal_entries_item ON meal_entries(item_id) WHERE item_id IS NOT NULL;
CREATE INDEX idx_meal_entries_dish ON meal_entries(dish_id) WHERE dish_id IS NOT NULL;

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
    )
$$;

DROP TABLE meal_items;
DROP TABLE user_meals;
