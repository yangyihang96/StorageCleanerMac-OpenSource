CREATE TABLE leaderboard_entries (
    id TEXT PRIMARY KEY,
    installation_hash TEXT NOT NULL,
    last_submission_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    processor_model TEXT NOT NULL,
    profile TEXT NOT NULL CHECK (profile IN ('quick', 'full')),
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
