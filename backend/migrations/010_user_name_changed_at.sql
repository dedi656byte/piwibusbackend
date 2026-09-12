ALTER TABLE piwibus_users
  ADD COLUMN IF NOT EXISTS name_changed_at timestamptz;
