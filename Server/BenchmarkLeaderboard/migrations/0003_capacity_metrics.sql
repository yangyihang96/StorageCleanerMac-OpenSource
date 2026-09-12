-- Store validated capacity metadata. The active v6 standard protocol uses
-- these fields in its frozen memory- and disk-capacity score components.
ALTER TABLE leaderboard_entries
ADD COLUMN physical_memory_bytes INTEGER;

ALTER TABLE leaderboard_entries
ADD COLUMN system_disk_capacity_bytes INTEGER;
