-- Add V7/v2 beside the existing v1/v6 table. This migration is intentionally
-- additive: deployed v1 clients and their rows remain untouched.
CREATE TABLE benchmark_v7_entries (
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
    confidence TEXT NOT NULL CHECK (confidence IN ('high', 'medium')),
    metrics_json TEXT NOT NULL CHECK (json_valid(metrics_json)),
    UNIQUE (installation_hash, workload_version)
);

CREATE INDEX benchmark_v7_ranking_idx
ON benchmark_v7_entries (
    workload_version,
    score DESC,
    completed_on ASC,
    id ASC
);

-- submission_id is the v2 idempotency boundary. request_hash detects reuse of
-- the same UUID with a different payload; receipt_json preserves exact replay.
CREATE TABLE benchmark_v7_submissions (
    submission_id TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,
    claim_token TEXT NOT NULL CHECK (length(claim_token) = 36),
    installation_hash TEXT NOT NULL,
    workload_version TEXT NOT NULL CHECK (workload_version = 'benchmark-standard-v9'),
    entry_id TEXT,
    disposition TEXT CHECK (
        disposition IS NULL OR disposition IN ('created', 'updated', 'unchanged')
    ),
    receipt_json TEXT CHECK (receipt_json IS NULL OR json_valid(receipt_json)),
    response_status INTEGER CHECK (
        response_status IS NULL OR response_status IN (200, 201)
    ),
    created_at TEXT NOT NULL
);

CREATE INDEX benchmark_v7_submission_owner_idx
ON benchmark_v7_submissions (installation_hash, workload_version);

CREATE INDEX benchmark_v7_submission_created_idx
ON benchmark_v7_submissions (created_at);

-- A deletion tombstone prevents an already-started or retried POST carrying an
-- older benchmark result from recreating a score after DELETE has completed.
CREATE TABLE benchmark_v7_deletions (
    installation_hash TEXT NOT NULL,
    workload_version TEXT NOT NULL CHECK (workload_version = 'benchmark-standard-v9'),
    deleted_at TEXT NOT NULL,
    PRIMARY KEY (installation_hash, workload_version)
);
