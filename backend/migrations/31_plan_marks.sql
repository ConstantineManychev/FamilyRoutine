ALTER TABLE plan_instances ADD COLUMN status_mark_id UUID REFERENCES status_marks(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX uq_plan_instances_mark ON plan_instances(status_mark_id) WHERE status_mark_id IS NOT NULL;
