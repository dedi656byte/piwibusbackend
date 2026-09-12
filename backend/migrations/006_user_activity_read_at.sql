ALTER TABLE piwibus_users
  ADD COLUMN IF NOT EXISTS activity_read_at timestamptz;
