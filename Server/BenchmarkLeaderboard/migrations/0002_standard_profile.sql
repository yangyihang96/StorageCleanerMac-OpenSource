-- Preserve all v3 leaderboard rows while allowing the single v4 standard
-- profile. SQLite cannot widen a CHECK constraint in place, so rebuild the
-- table and copy every existing row before restoring the indexes.
CREATE TABLE leaderboard_entries_v2 (
    id TEXT PRIMARY KEY,
    installation_hash TEXT NOT NULL,
    last_submission_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    processor_model TEXT NOT NULL,
    profile TEXT NOT NULL CHECK (profile IN ('standard', 'quick', 'full')),
    workload_version TEXT NOT NULL,
    baseline_version TEXT NOT NULL,
    architecture TEXT NOT NULL CHECK (architecture = 'arm64'),
    score REAL NOT NULL CHECK (score > 0 AND score <= 30000),
    cpu_single REAL NOT NULL CHECK (cpu_single > 0),
    cpu_multi REAL NOT NULL CHECK (cpu_multi > 0),
    gpu REAL NOT NULL CHECK (gpu > 0),
    memory REAL NOT NULL CHECK (memory > 0),
    disk_read REAL NOT NULL CHECK (disk_read > 0),
    disk_write REAL NOT NULL CHECK (disk_write > 0),
    completed_at TEXT NOT NULL,
    submitted_at TEXT NOT NULL,
    app_version TEXT NOT NULL,
    app_build TEXT NOT NULL,
    UNIQUE (installation_hash, profile, workload_version)
);

INSERT INTO leaderboard_entries_v2 (
    id,
    installation_hash,
    last_submission_id,
    display_name,
    processor_model,
    profile,
    workload_version,
    baseline_version,
    architecture,
    score,
    cpu_single,
    cpu_multi,
    gpu,
    memory,
    disk_read,
    disk_write,
    completed_at,
    submitted_at,
    app_version,
    app_build
)
SELECT
    id,
    installation_hash,
    last_submission_id,
    display_name,
    processor_model,
    profile,
    workload_version,
    baseline_version,
    architecture,
    score,
    cpu_single,
    cpu_multi,
    gpu,
    memory,
    disk_read,
    disk_write,
    completed_at,
    submitted_at,
    app_version,
    app_build
FROM leaderboard_entries;

DROP TABLE leaderboard_entries;
ALTER TABLE leaderboard_entries_v2 RENAME TO leaderboard_entries;

CREATE INDEX leaderboard_ranking_idx
ON leaderboard_entries (
    profile,
    workload_version,
    score DESC,
    completed_at ASC,
    id ASC
);

CREATE INDEX leaderboard_submission_idx
ON leaderboard_entries (last_submission_id);
