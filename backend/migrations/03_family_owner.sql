DELETE FROM families f WHERE NOT EXISTS (SELECT 1 FROM family_mems m WHERE m.family_id = f.id);

ALTER TABLE families ADD COLUMN owner_id UUID;

UPDATE families f
SET owner_id = (
    SELECT m.user_id
    FROM family_mems m
    WHERE m.family_id = f.id
    ORDER BY (m.role = 'admin') DESC, m.joined_ts, m.user_id
    LIMIT 1
);

UPDATE family_mems m
SET role = 'admin'
FROM families f
WHERE f.id = m.family_id AND f.owner_id = m.user_id;

ALTER TABLE families ALTER COLUMN owner_id SET NOT NULL;

ALTER TABLE families ADD CONSTRAINT families_owner_member_fkey
    FOREIGN KEY (id, owner_id) REFERENCES family_mems(family_id, user_id)
    DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX idx_families_owner ON families(owner_id);
