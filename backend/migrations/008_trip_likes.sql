ALTER TABLE piwibus_trips
ADD COLUMN IF NOT EXISTS liked_by_actor_ids text[] NOT NULL DEFAULT '{}';
