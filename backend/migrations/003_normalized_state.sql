CREATE TABLE IF NOT EXISTS piwibus_meta (
  id text PRIMARY KEY,
  revision bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS piwibus_users (
  id text PRIMARY KEY,
  sort_order integer NOT NULL,
  full_name text NOT NULL,
  email text NOT NULL UNIQUE,
  phone text NOT NULL DEFAULT '',
  name_changed_at timestamptz,
  primary_role text NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL,
  last_seen_at timestamptz,
  password_hash text NOT NULL
);

CREATE INDEX IF NOT EXISTS piwibus_users_status_idx
ON piwibus_users (status, created_at DESC);

CREATE TABLE IF NOT EXISTS piwibus_sessions (
  session_id text PRIMARY KEY,
  current_user_id text,
  active_role text NOT NULL,
  section text NOT NULL,
  search_query text NOT NULL DEFAULT '',
  selected_line_code text,
  selected_trip_id text,
  favorite_line_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
  current_location jsonb,
  created_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS piwibus_sessions_last_seen_idx
ON piwibus_sessions (last_seen_at DESC);

CREATE TABLE IF NOT EXISTS piwibus_trips (
  id text PRIMARY KEY,
  sort_order integer NOT NULL,
  line_code text NOT NULL,
  owner_id text,
  owner_session_id text,
  owner_name text NOT NULL,
  owner_role text NOT NULL,
  status text NOT NULL,
  started_at timestamptz NOT NULL,
  last_updated_at timestamptz NOT NULL,
  progress double precision NOT NULL,
  speed_kmh double precision NOT NULL,
  observers integer NOT NULL,
  max_observers integer NOT NULL DEFAULT 0,
  network_usage_bytes bigint NOT NULL DEFAULT 0,
  rating_average double precision NOT NULL,
  rating_count integer NOT NULL,
  liked_by_actor_ids text[] NOT NULL DEFAULT '{}',
  note text NOT NULL,
  live_location jsonb,
  path jsonb NOT NULL DEFAULT '[]'::jsonb,
  origin_label text NOT NULL,
  destination_label text NOT NULL
);

CREATE INDEX IF NOT EXISTS piwibus_trips_status_updated_idx
ON piwibus_trips (status, last_updated_at DESC);

CREATE TABLE IF NOT EXISTS piwibus_trip_messages (
  trip_id text NOT NULL REFERENCES piwibus_trips(id) ON DELETE CASCADE,
  message_id text NOT NULL,
  message_order integer NOT NULL,
  author_name text NOT NULL,
  role text NOT NULL,
  content text NOT NULL,
  created_at timestamptz NOT NULL,
  is_system boolean NOT NULL DEFAULT false,
  PRIMARY KEY (trip_id, message_id)
);

CREATE INDEX IF NOT EXISTS piwibus_trip_messages_trip_idx
ON piwibus_trip_messages (trip_id, message_order, created_at);

CREATE TABLE IF NOT EXISTS piwibus_reports (
  id text PRIMARY KEY,
  sort_order integer NOT NULL,
  bus_number text NOT NULL,
  line_code text NOT NULL,
  line_label text NOT NULL,
  reporter_id text,
  reporter_name text NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL,
  note text NOT NULL,
  confidence double precision NOT NULL
);

CREATE INDEX IF NOT EXISTS piwibus_reports_status_created_idx
ON piwibus_reports (status, created_at DESC);

CREATE TABLE IF NOT EXISTS piwibus_push_tokens (
  id text PRIMARY KEY,
  sort_order integer NOT NULL,
  token text NOT NULL UNIQUE,
  platform text NOT NULL,
  session_id text,
  user_id text,
  status text NOT NULL,
  created_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS piwibus_push_tokens_status_idx
ON piwibus_push_tokens (status, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS piwibus_activity (
  position integer PRIMARY KEY,
  title text NOT NULL,
  subtitle text NOT NULL,
  timestamp timestamptz NOT NULL,
  icon_key text NOT NULL,
  color_value bigint NOT NULL,
  audience_session_ids jsonb NOT NULL DEFAULT '[]'::jsonb
);
