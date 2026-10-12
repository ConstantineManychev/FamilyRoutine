ALTER TABLE place_addrs ALTER COLUMN street_id DROP NOT NULL;
ALTER TABLE place_addrs ALTER COLUMN house_num DROP NOT NULL;
UPDATE place_addrs SET house_num = NULL WHERE TRIM(house_num) = '';
UPDATE place_addrs SET zip = NULL WHERE TRIM(zip) = '';

CREATE FUNCTION addr_label(a_city TEXT, a_street TEXT, a_house TEXT, a_zip TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(CONCAT_WS(
        ', ',
        a_city,
        NULLIF(CONCAT_WS(' ', a_street, a_house), ''),
        CASE WHEN a_street IS NULL AND a_house IS NULL THEN a_zip END
    ), '')
$$;

CREATE TABLE merchant_places (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    merchant_id UUID NOT NULL REFERENCES merchants(id) ON DELETE CASCADE,
    place_id UUID NOT NULL REFERENCES places(id) ON DELETE CASCADE,
    place_addr_id UUID REFERENCES place_addrs(id) ON DELETE SET NULL,
    updated_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, merchant_id)
);
CREATE INDEX idx_merchant_places_place ON merchant_places(place_id);

INSERT INTO merchant_places (user_id, merchant_id, place_id, place_addr_id)
SELECT DISTINCT ON (COALESCE(p.created_by, p.owner_id), m.id)
    COALESCE(p.created_by, p.owner_id), m.id, pa.place_id, pa.id
FROM place_addrs pa
JOIN places p ON p.id = pa.place_id
JOIN merchants m ON m.name_key = LOWER(TRIM(REGEXP_REPLACE(pa.merchant_id, '[^[:alnum:]]+', ' ', 'g')))
WHERE pa.merchant_id IS NOT NULL AND COALESCE(p.created_by, p.owner_id) IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE place_addrs DROP COLUMN merchant_id;

UPDATE transactions SET rule_key = NULL WHERE source = 'bank' AND merchant_id IS NULL AND amount < 0;
