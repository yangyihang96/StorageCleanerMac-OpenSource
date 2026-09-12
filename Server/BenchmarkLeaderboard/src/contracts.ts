export const API_SCHEMA_VERSION = 1;
export const ACTIVE_BASELINE_VERSION = "m5-pro-2026-07-v6";
export const LEGACY_STANDARD_BASELINE_VERSION = "m5-pro-2026-07-v4";
export const LEGACY_BASELINE_VERSION = "m5-pro-2026-07-v3";
export const DEFAULT_PAGE_SIZE = 50;
export const MAX_PAGE_SIZE = 100;
export const MAX_REQUEST_BYTES = 16_384;

export type BenchmarkProfile = "standard" | "quick" | "full";

// Known versions include protocols that may already exist in local/server data.
// Being known does not imply that a version has a frozen reference, may accept
// submissions, or may be exposed by the public leaderboard.
export const KNOWN_WORKLOAD_VERSIONS = [
  "mac-benchmark-standard-v6",
  "mac-benchmark-standard-v5",
  "mac-benchmark-standard-v4",
  "mac-benchmark-quick-v3",
  "mac-benchmark-full-v3",
] as const;
export type WorkloadVersion = (typeof KNOWN_WORKLOAD_VERSIONS)[number];

export const FROZEN_WORKLOAD_VERSIONS = [
  "mac-benchmark-standard-v6",
  "mac-benchmark-standard-v4",
  "mac-benchmark-quick-v3",
  "mac-benchmark-full-v3",
] as const;
export type FrozenWorkloadVersion = (typeof FROZEN_WORKLOAD_VERSIONS)[number];

export type BaselineVersion =
  | typeof ACTIVE_BASELINE_VERSION
  | typeof LEGACY_STANDARD_BASELINE_VERSION
  | typeof LEGACY_BASELINE_VERSION;

export const PROFILE_BY_WORKLOAD: Record<WorkloadVersion, BenchmarkProfile> = {
  "mac-benchmark-standard-v6": "standard",
  "mac-benchmark-standard-v5": "standard",
  "mac-benchmark-standard-v4": "standard",
  "mac-benchmark-quick-v3": "quick",
  "mac-benchmark-full-v3": "full",
};

// Active selects the default production protocol for each profile. It is kept
// separate from the accepted/queryable/deletable sets so a newly recognised
// workload cannot become public before calibration is frozen.
export const ACTIVE_WORKLOAD_BY_PROFILE: Record<
  BenchmarkProfile,
  FrozenWorkloadVersion
> = {
  standard: "mac-benchmark-standard-v6",
  quick: "mac-benchmark-quick-v3",
  full: "mac-benchmark-full-v3",
};

export const ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE: Record<
  BenchmarkProfile,
  readonly WorkloadVersion[]
> = {
  standard: ["mac-benchmark-standard-v6"],
  quick: [],
  full: [],
};

export const QUERYABLE_WORKLOADS_BY_PROFILE: Record<
  BenchmarkProfile,
  readonly WorkloadVersion[]
> = {
  standard: ["mac-benchmark-standard-v6"],
  quick: [],
  full: [],
};

// Deletion intentionally recognises uncalibrated v5 so stale or accidental
// rows can be removed without making that protocol submit/query capable.
export const DELETABLE_WORKLOADS_BY_PROFILE: Record<
  BenchmarkProfile,
  readonly WorkloadVersion[]
> = {
  standard: [
    "mac-benchmark-standard-v4",
    "mac-benchmark-standard-v5",
    "mac-benchmark-standard-v6",
  ],
  quick: ["mac-benchmark-quick-v3"],
  full: ["mac-benchmark-full-v3"],
};

// Only genuinely frozen workloads may appear in these maps. v6 uses its own
// formal calibration and never aliases the legacy v4 measurements.
export const BASELINE_BY_WORKLOAD: Record<
  FrozenWorkloadVersion,
  BaselineVersion
> = {
  "mac-benchmark-standard-v6": ACTIVE_BASELINE_VERSION,
  "mac-benchmark-standard-v4": LEGACY_STANDARD_BASELINE_VERSION,
  "mac-benchmark-quick-v3": LEGACY_BASELINE_VERSION,
  "mac-benchmark-full-v3": LEGACY_BASELINE_VERSION,
};

// appVersion describes the source benchmark run, not the uploader version.
export const MINIMUM_SOURCE_APP_VERSION_BY_WORKLOAD: Record<
  FrozenWorkloadVersion,
  string
> = {
  "mac-benchmark-standard-v6": "1.8.2",
  "mac-benchmark-standard-v4": "1.8.2",
  "mac-benchmark-quick-v3": "1.6.0",
  "mac-benchmark-full-v3": "1.6.0",
};

export const REFERENCE_METRICS: Record<
  FrozenWorkloadVersion,
  BenchmarkMetrics
> = {
  "mac-benchmark-standard-v6": {
    cpuSingle: 420.57305150435,
    cpuMulti: 6946.964858253779,
    gpu: 3078.317339594168,
    memory: 29.989172821353254,
    diskRead: 0.1979672398839487,
    diskWrite: 2.029915386980515,
    physicalMemoryBytes: 51_539_607_552,
    systemDiskCapacityBytes: 994_610_155_520,
  },
  "mac-benchmark-standard-v4": {
    cpuSingle: 419.1196801333099,
    cpuMulti: 6906.347386987738,
    gpu: 2513.0478676546404,
    memory: 28.187976553597323,
    diskRead: 0.18612222255500788,
    diskWrite: 2.042645076723868,
  },
  "mac-benchmark-quick-v3": {
    cpuSingle: 413.8602006135609,
    cpuMulti: 6924.682398285569,
    gpu: 3319.9957532003536,
    memory: 29.962937118120166,
    diskRead: 0.1895410119265057,
    diskWrite: 1.9313032427640975,
  },
  "mac-benchmark-full-v3": {
    cpuSingle: 416.07855121003325,
    cpuMulti: 6831.154217573838,
    gpu: 3380.7942562980334,
    memory: 29.32133464841806,
    diskRead: 0.19073777964603722,
    diskWrite: 7.073967102664943,
  },
};

export function isKnownWorkloadVersion(value: unknown): value is WorkloadVersion {
  return typeof value === "string"
    && (KNOWN_WORKLOAD_VERSIONS as readonly string[]).includes(value);
}

export function isFrozenWorkloadVersion(
  value: WorkloadVersion,
): value is FrozenWorkloadVersion {
  return (FROZEN_WORKLOAD_VERSIONS as readonly WorkloadVersion[]).includes(value);
}

export interface BenchmarkMetricStability {
  coefficientOfVariation: number;
  sampleCount: number;
}

export interface BenchmarkStabilityEvidence {
  cpuSingle: BenchmarkMetricStability;
  cpuMulti: BenchmarkMetricStability;
  gpu: BenchmarkMetricStability;
  memory: BenchmarkMetricStability;
  diskRead: BenchmarkMetricStability;
  diskWrite: BenchmarkMetricStability;
}

export interface BenchmarkMetrics {
  cpuSingle: number;
  cpuMulti: number;
  gpu: number;
  memory: number;
  diskRead: number;
  diskWrite: number;
  // v3/v4 keep these as optional private metadata. Standard v6 requires both
  // values and uses their bounded contribution in the memory/disk components.
  physicalMemoryBytes?: number;
  systemDiskCapacityBytes?: number;
  // Optional for frozen v3/v4 compatibility. The v6 protocol requires all six
  // entries before it can ever be activated for public submissions.
  stability?: BenchmarkStabilityEvidence;
}

export interface BenchmarkConditions {
  powerSource: "acPower";
  lowPowerModeEnabled: false;
  preflightThermalState: "nominal";
  postflightThermalState: "nominal";
}

export interface SubmissionRequest {
  submissionId: string;
  installationId: string;
  displayName: string;
  processorModel: string;
  profile: BenchmarkProfile;
  workloadVersion: FrozenWorkloadVersion;
  baselineVersion: BaselineVersion;
  architecture: "arm64";
  completedAt: string;
  appVersion: string;
  appBuild: string;
  conditions: BenchmarkConditions;
  metrics: BenchmarkMetrics;
  proposedScore: number;
}

export interface DeletionRequest {
  installationId: string;
  profile: BenchmarkProfile;
  workloadVersion: WorkloadVersion;
}

export interface ValidatedSubmission extends SubmissionRequest {
  completedAt: string;
  displayName: string;
  processorModel: string;
  proposedScore: number;
}

export interface LeaderboardRow {
  id: string;
  display_name: string;
  processor_model: string;
  score: number;
  profile: BenchmarkProfile;
  workload_version: WorkloadVersion;
  physical_memory_bytes: number;
  system_disk_capacity_bytes: number;
  completed_at: string;
}

export interface Env {
  DB: D1Database;
  IDENTITY_HMAC_KEY: string;
  SUBMISSION_RATE_LIMITER?: RateLimit;
}
