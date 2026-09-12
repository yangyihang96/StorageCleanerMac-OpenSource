import type { Env } from "./contracts";

export const V2_API_SCHEMA_VERSION = 2;
export const V2_PLAN_VERSION = "benchmark-standard-plan-v9";
export const V2_WORKLOAD_VERSION = "benchmark-standard-v9";
export const V2_SCORING_VERSION = "benchmark-scoring-v9";
export const V2_REFERENCE_SET_VERSION = "local-m5-pro-controlled-v9-r1";
export const V2_DISPLAY_BASELINE = 6_000;
// The shipped Swift client rejects public rows above one million points. A
// per-metric ratio bound at the corresponding mathematical ceiling prevents a
// single fabricated metric (including lower-is-better latency) from creating
// a row the client cannot decode.
export const V2_MAX_PUBLIC_SCORE = 1_000_000;
export const V2_MAX_METRIC_RATIO = V2_MAX_PUBLIC_SCORE / V2_DISPLAY_BASELINE;
export const V2_DEFAULT_PAGE_SIZE = 50;
export const V2_MAX_PAGE_SIZE = 100;
export const V2_MAX_REQUEST_BYTES = 32_768;
export const V2_SUBMISSION_RECEIPT_RETENTION_DAYS = 90;

export type V2MetricDirection = "higherIsBetter" | "lowerIsBetter";
export type V2CoreCategory = "cpu" | "gpu" | "memory" | "storage";

export interface V2MetricDefinition {
  id: string;
  category: V2CoreCategory;
  direction: V2MetricDirection;
  weight: number;
  reference: number;
}

export const V2_CATEGORY_WEIGHTS: Readonly<Record<V2CoreCategory, number>> = {
  cpu: 0.35,
  gpu: 0.25,
  memory: 0.20,
  storage: 0.20,
};

// Mirrors BenchmarkV7ReferenceCatalog.swift exactly. Keep this list ordered so
// canonical request hashes and score calculations are stable across replays.
export const V2_CORE_METRICS = [
  metric("cpu.single.mixed", "cpu", "higherIsBetter", 0.50, 608.1329522317399),
  metric("cpu.multi.particle", "cpu", "higherIsBetter", 0.50, 18_260.298333995146),
  metric("gpu.graphics.offscreen", "gpu", "higherIsBetter", 0.50, 2_086.749841859349),
  metric("gpu.compute.fp16", "gpu", "higherIsBetter", 0.50, 30.786266568177105),
  metric("memory.copy.bandwidth", "memory", "higherIsBetter", 0.33, 127.63647239227342),
  metric("memory.triad.bandwidth", "memory", "higherIsBetter", 0.33, 118.85707538634516),
  metric("memory.pointer-chase.latency", "memory", "lowerIsBetter", 0.34, 106.66351515054703),
  metric("storage.sequential.read", "storage", "higherIsBetter", 0.10, 0.18881157289488334),
  metric("storage.sequential.write", "storage", "higherIsBetter", 0.10, 6.719252765593533),
  metric("storage.random.read.qd1.iops", "storage", "higherIsBetter", 0.10, 11_582.830066295159),
  metric("storage.random.read.qd1.latency.p50.ns", "storage", "lowerIsBetter", 0.05, 80_333),
  metric("storage.random.read.qd1.latency.p95.ns", "storage", "lowerIsBetter", 0.05, 115_166),
  metric("storage.random.read.qd16.iops", "storage", "higherIsBetter", 0.10, 120_595.28464634847),
  metric("storage.random.read.qd16.latency.p50.ns", "storage", "lowerIsBetter", 0.05, 125_729.5),
  metric("storage.random.read.qd16.latency.p95.ns", "storage", "lowerIsBetter", 0.05, 188_333),
  metric("storage.random.write.qd1.iops", "storage", "higherIsBetter", 0.10, 9_421.382455536668),
  metric("storage.random.write.qd1.latency.p50.ns", "storage", "lowerIsBetter", 0.05, 89_041),
  metric("storage.random.write.qd1.latency.p95.ns", "storage", "lowerIsBetter", 0.05, 128_666),
  metric("storage.random.write.qd16.iops", "storage", "higherIsBetter", 0.10, 34_716.918145612006),
  metric("storage.random.write.qd16.latency.p50.ns", "storage", "lowerIsBetter", 0.05, 236_146),
  metric("storage.random.write.qd16.latency.p95.ns", "storage", "lowerIsBetter", 0.05, 1_464_208),
] as const satisfies readonly V2MetricDefinition[];

export type V2MetricID = (typeof V2_CORE_METRICS)[number]["id"];
export type V2Metrics = Record<V2MetricID, number>;

export interface V2BenchmarkConditions {
  powerSource: "acPower";
  lowPowerModeEnabled: false;
  thermalState: "nominal";
  confidence: "high" | "medium" | "low";
  sustainedReachedTargetDuration: true;
}

export interface V2SubmissionRequest {
  submissionId: string;
  installationId: string;
  displayName: string;
  computerModel: string;
  processorModel: string;
  memoryGB: number;
  architecture: "arm64";
  planVersion: typeof V2_PLAN_VERSION;
  workloadVersion: typeof V2_WORKLOAD_VERSION;
  scoringVersion: typeof V2_SCORING_VERSION;
  referenceSetVersion: typeof V2_REFERENCE_SET_VERSION;
  completedAt: string;
  appVersion: string;
  appBuild: string;
  conditions: V2BenchmarkConditions;
  metrics: V2Metrics;
  proposedScore: number;
}

export interface V2ValidatedSubmission extends V2SubmissionRequest {
  completedOn: string;
}

export interface V2DeletionRequest {
  installationId: string;
  workloadVersion: typeof V2_WORKLOAD_VERSION;
}

export interface V2LeaderboardRow {
  id: string;
  display_name: string;
  computer_model: string;
  processor_model: string;
  memory_gb: number;
  score: number;
  workload_version: string;
  completed_on: string;
  confidence: string;
}

export interface V2RankedRow extends V2LeaderboardRow {
  rank: number;
}

export interface V2PublicEntry {
  id: string;
  rank: number;
  displayName: string;
  computerModel: string;
  processorModel: string;
  memoryGB: number;
  score: number;
  workloadVersion: string;
  completedOn: string;
  confidence: string;
}

export interface V2Receipt {
  data: V2PublicEntry;
  disposition: "created" | "updated" | "unchanged";
  meta: V2VersionMetadata & { submittedAt: string };
}

export interface V2VersionMetadata {
  planVersion: typeof V2_PLAN_VERSION;
  workloadVersion: typeof V2_WORKLOAD_VERSION;
  scoringVersion: typeof V2_SCORING_VERSION;
  referenceSetVersion: typeof V2_REFERENCE_SET_VERSION;
}

export interface V2Env extends Env {
  SUBMISSION_RATE_LIMITER?: RateLimit;
}

function metric<const ID extends string>(
  id: ID,
  category: V2CoreCategory,
  direction: V2MetricDirection,
  weight: number,
  reference: number,
): V2MetricDefinition & { id: ID } {
  return { id, category, direction, weight, reference };
}
