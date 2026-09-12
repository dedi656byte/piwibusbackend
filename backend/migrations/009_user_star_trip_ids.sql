ALTER TABLE piwibus_users
  ADD COLUMN IF NOT EXISTS star_trip_ids text[] NOT NULL DEFAULT '{}';
