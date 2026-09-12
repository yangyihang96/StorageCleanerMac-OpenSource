-- Allow low-confidence entries on the public leaderboard per owner decision.
-- SQLite cannot alter a CHECK constraint in place, so rebuild the (empty or
-- small) table with the widened constraint and restore the same shape/index.
CREATE TABLE benchmark_v7_entries_new (
    id TEXT PRIMARY KEY,
    installation_hash TEXT NOT NULL,
    last_submission_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    computer_model TEXT NOT NULL,
    processor_model TEXT NOT NULL,
    memory_gb INTEGER NOT NULL CHECK (memory_gb > 0 AND memory_gb <= 2048),
    architecture TEXT NOT NULL CHECK (architecture = 'arm64'),
    plan_version TEXT NOT NULL CHECK (plan_version = 'benchmark-standard-plan-v9'),
    workload_version TEXT NOT NULL CHECK (workload_version = 'benchmark-standard-v9'),
    scoring_version TEXT NOT NULL CHECK (scoring_version = 'benchmark-scoring-v9'),
    reference_set_version TEXT NOT NULL CHECK (reference_set_version = 'local-m5-pro-controlled-v9-r1'),
    score REAL NOT NULL CHECK (score > 0 AND score <= 1000000),
    completed_at TEXT NOT NULL,
    completed_on TEXT NOT NULL,
    submitted_at TEXT NOT NULL,
    app_version TEXT NOT NULL,
    app_build TEXT NOT NULL,
    confidence TEXT NOT NULL CHECK (confidence IN ('high', 'medium', 'low')),
    metrics_json TEXT NOT NULL CHECK (json_valid(metrics_json)),
    UNIQUE (installation_hash, workload_version)
);

INSERT INTO benchmark_v7_entries_new (
    id, installation_hash, last_submission_id, display_name,
    computer_model, processor_model, memory_gb, architecture,
    plan_version, workload_version, scoring_version,
    reference_set_version, score, completed_at, completed_on,
    submitted_at, app_version, app_build, confidence, metrics_json
)
SELECT
    id, installation_hash, last_submission_id, display_name,
    computer_model, processor_model, memory_gb, architecture,
    plan_version, workload_version, scoring_version,
    reference_set_version, score, completed_at, completed_on,
    submitted_at, app_version, app_build, confidence, metrics_json
FROM benchmark_v7_entries;

DROP TABLE benchmark_v7_entries;

ALTER TABLE benchmark_v7_entries_new RENAME TO benchmark_v7_entries;

CREATE INDEX benchmark_v7_ranking_idx
ON benchmark_v7_entries (
    workload_version,
    score DESC,
    completed_on ASC,
    id ASC
);
