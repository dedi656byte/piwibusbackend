ALTER TABLE piwibus_trip_locations
ADD COLUMN IF NOT EXISTS location geography(Point, 4326);

CREATE INDEX IF NOT EXISTS piwibus_trip_locations_location_gix
ON piwibus_trip_locations USING GIST (location);
