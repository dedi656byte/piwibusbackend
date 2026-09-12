CREATE TABLE IF NOT EXISTS piwibus_schema_migrations (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS piwibus_state (
  id text PRIMARY KEY,
  payload jsonb NOT NULL,
  revision bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS piwibus_trip_locations (
  trip_id text PRIMARY KEY,
  line_code text NOT NULL,
  owner_id text,
  status text NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS piwibus_trip_locations_status_idx
ON piwibus_trip_locations (status, updated_at DESC);
