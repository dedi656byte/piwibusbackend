ALTER TABLE piwibus_users
  ADD COLUMN IF NOT EXISTS read_alert_ids text[] NOT NULL DEFAULT '{}';
