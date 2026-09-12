ALTER TABLE piwibus_trips
ADD COLUMN IF NOT EXISTS max_observers integer NOT NULL DEFAULT 0;

UPDATE piwibus_trips
SET max_observers = observers
WHERE max_observers < observers;

ALTER TABLE piwibus_trips
ADD COLUMN IF NOT EXISTS network_usage_bytes bigint NOT NULL DEFAULT 0;
