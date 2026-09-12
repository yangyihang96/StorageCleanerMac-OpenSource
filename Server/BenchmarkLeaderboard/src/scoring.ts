import {
  ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE,
  BASELINE_BY_WORKLOAD,
  DELETABLE_WORKLOADS_BY_PROFILE,
  MINIMUM_SOURCE_APP_VERSION_BY_WORKLOAD,
  PROFILE_BY_WORKLOAD,
  QUERYABLE_WORKLOADS_BY_PROFILE,
  REFERENCE_METRICS,
  isFrozenWorkloadVersion,
  isKnownWorkloadVersion,
  type BenchmarkMetrics,
  type BenchmarkProfile,
  type BenchmarkStabilityEvidence,
  type DeletionRequest,
  type FrozenWorkloadVersion,
  type SubmissionRequest,
  type ValidatedSubmission,
  type WorkloadVersion,
} from "./contracts";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const APP_BUILD_PATTERN = /^[0-9]{8,20}$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/u;
const METRIC_KEYS = [
  "cpuSingle",
  "cpuMulti",
  "gpu",
  "memory",
  "diskRead",
  "diskWrite",
] as const;
export type MetricKey = (typeof METRIC_KEYS)[number];

export const V6_REFERENCE_TOTAL_SCORE = 6_000;
export const V6_REFERENCE_PHYSICAL_MEMORY_BYTES = 51_539_607_552;
export const V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES = 994_610_155_520;
export const V6_MEMORY_PERFORMANCE_WEIGHT = 0.75;
export const V6_MEMORY_CAPACITY_WEIGHT = 0.25;
export const V6_DISK_PERFORMANCE_WEIGHT = 0.90;
export const V6_DISK_CAPACITY_WEIGHT = 0.10;
export const V6_MINIMUM_CAPACITY_RATIO = 0.25;
export const V6_MAXIMUM_CAPACITY_RATIO = 2;
export const V6_MINIMUM_PERFORMANCE_RATIO = 0.02;
export const V6_MAXIMUM_PERFORMANCE_RATIO = 5;
export const V6_BALANCED_WEIGHTS: Readonly<Record<MetricKey, number>> = {
  cpuSingle: 0.14,
  cpuMulti: 0.21,
  gpu: 0.25,
  memory: 0.20,
  diskRead: 0.11,
  diskWrite: 0.09,
};
export const V6_REQUIRED_SAMPLE_COUNT = 3;
export const V6_MAXIMUM_COEFFICIENT_OF_VARIATION: Readonly<
  Record<MetricKey, number>
> = {
  cpuSingle: 0.05,
  cpuMulti: 0.05,
  gpu: 0.10,
  memory: 0.05,
  diskRead: 0.05,
  diskWrite: 0.10,
};
export type BenchmarkMetricRatios = Record<MetricKey, number>;
export interface V6CapacityBytes {
  physicalMemoryBytes: number;
  systemDiskCapacityBytes: number;
}

export class SubmissionValidationError extends Error {
  constructor(
    readonly field: string,
    readonly code = "invalid_submission",
  ) {
    super(`Invalid leaderboard submission field: ${field}`);
  }
}

export function computeScore(
  workloadVersion: FrozenWorkloadVersion,
  metrics: BenchmarkMetrics,
): number {
  const reference = REFERENCE_METRICS[workloadVersion];
  if (workloadVersion === "mac-benchmark-standard-v6") {
    const { physicalMemoryBytes, systemDiskCapacityBytes } = metrics;
    if (
      physicalMemoryBytes === undefined
      || systemDiskCapacityBytes === undefined
    ) {
      throw new RangeError("missing v6 capacity evidence");
    }
    const ratios = Object.fromEntries(
      METRIC_KEYS.map((key) => [key, metrics[key] / reference[key]]),
    ) as BenchmarkMetricRatios;
    return computeV6BalancedCompositeScore(ratios, {
      physicalMemoryBytes,
      systemDiskCapacityBytes,
    });
  }
  return METRIC_KEYS.reduce((total, key) => {
    const ratio = metrics[key] / reference[key];
    return total + 1_000 * Math.min(5, Math.max(0.2, ratio));
  }, 0);
}

// Frozen v6 implementation. Ratios are derived from the formal reference map
// before bounded memory and system-disk capacity contributions are applied.
export function computeV6BalancedCompositeScore(
  ratios: BenchmarkMetricRatios,
  capacityBytes: V6CapacityBytes,
): number {
  validateV6PerformanceRatios(ratios);
  const effectiveRatios = computeV6EffectiveRatios(ratios, capacityBytes);
  let weightedLogRatio = 0;
  for (const key of METRIC_KEYS) {
    weightedLogRatio += V6_BALANCED_WEIGHTS[key]
      * Math.log(effectiveRatios[key]);
  }
  return V6_REFERENCE_TOTAL_SCORE * Math.exp(weightedLogRatio);
}

export function computeV6EffectiveRatios(
  ratios: BenchmarkMetricRatios,
  capacityBytes: V6CapacityBytes,
): BenchmarkMetricRatios {
  const memoryCapacityRatio = boundedCapacityRatio(
    capacityBytes.physicalMemoryBytes,
    V6_REFERENCE_PHYSICAL_MEMORY_BYTES,
  );
  const diskCapacityRatio = boundedCapacityRatio(
    capacityBytes.systemDiskCapacityBytes,
    V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES,
  );
  return {
    ...ratios,
    memory: V6_MEMORY_PERFORMANCE_WEIGHT * ratios.memory
      + V6_MEMORY_CAPACITY_WEIGHT * memoryCapacityRatio,
    diskRead: V6_DISK_PERFORMANCE_WEIGHT * ratios.diskRead
      + V6_DISK_CAPACITY_WEIGHT * diskCapacityRatio,
    diskWrite: V6_DISK_PERFORMANCE_WEIGHT * ratios.diskWrite
      + V6_DISK_CAPACITY_WEIGHT * diskCapacityRatio,
  };
}

function boundedCapacityRatio(actualBytes: number, referenceBytes: number): number {
  if (!Number.isSafeInteger(actualBytes) || actualBytes <= 0) {
    throw new RangeError("invalid v6 capacity");
  }
  const ratio = Math.sqrt(actualBytes / referenceBytes);
  if (!Number.isFinite(ratio) || ratio <= 0) {
    throw new RangeError("invalid v6 capacity ratio");
  }
  return Math.min(
    V6_MAXIMUM_CAPACITY_RATIO,
    Math.max(V6_MINIMUM_CAPACITY_RATIO, ratio),
  );
}

function validateV6PerformanceRatios(
  ratios: BenchmarkMetricRatios,
): void {
  for (const key of METRIC_KEYS) {
    const ratio = ratios[key];
    if (
      !Number.isFinite(ratio)
      || ratio < V6_MINIMUM_PERFORMANCE_RATIO
      || ratio > V6_MAXIMUM_PERFORMANCE_RATIO
    ) {
      throw new RangeError(`v6 ratio out of range: ${key}`);
    }
  }
}

export function validateLeaderboardWorkload(
  profile: BenchmarkProfile,
  value: unknown,
): FrozenWorkloadVersion {
  const workloadVersion = workloadValue(value);
  requireMatchingProfile(profile, workloadVersion);
  if (
    !containsWorkload(QUERYABLE_WORKLOADS_BY_PROFILE[profile], workloadVersion)
    || !isFrozenWorkloadVersion(workloadVersion)
  ) {
    throw new SubmissionValidationError(
      "workloadVersion",
      "unsupported_workload_version",
    );
  }
  return workloadVersion;
}

// Validates only the public activation policy before the full protocol parser.
export function validateSubmissionWorkloadActivation(
  value: unknown,
): FrozenWorkloadVersion {
  const body = objectValue(value, "body");
  const profile = profileValue(body.profile);
  const requestedWorkload = workloadValue(body.workloadVersion);
  requireMatchingProfile(profile, requestedWorkload);
  return activatedSubmissionWorkload(profile, requestedWorkload);
}

export function validateMetricStabilityEvidence(
  workloadVersion: WorkloadVersion,
  value: unknown,
): BenchmarkStabilityEvidence | undefined {
  if (value === undefined) {
    if (workloadVersion === "mac-benchmark-standard-v6") {
      throw new SubmissionValidationError("metrics.stability");
    }
    return undefined;
  }

  const stabilityObject = objectValue(value, "metrics.stability");
  const entries = Object.fromEntries(METRIC_KEYS.map((key) => {
    const field = `metrics.stability.${key}`;
    const entry = objectValue(stabilityObject[key], field);
    const coefficientOfVariation = nonNegativeFiniteNumber(
      entry.coefficientOfVariation,
      `${field}.coefficientOfVariation`,
    );
    const sampleCount = positiveSafeInteger(
      entry.sampleCount,
      `${field}.sampleCount`,
    );

    if (workloadVersion === "mac-benchmark-standard-v6") {
      if (sampleCount !== V6_REQUIRED_SAMPLE_COUNT) {
        throw new SubmissionValidationError(`${field}.sampleCount`);
      }
      if (
        coefficientOfVariation
          > V6_MAXIMUM_COEFFICIENT_OF_VARIATION[key]
      ) {
        throw new SubmissionValidationError(
          `${field}.coefficientOfVariation`,
        );
      }
    }

    return [key, { coefficientOfVariation, sampleCount }];
  })) as unknown as BenchmarkStabilityEvidence;

  return entries;
}

export function validateSubmission(
  value: unknown,
  now = new Date(),
): ValidatedSubmission {
  const body = objectValue(value, "body");
  const submissionId = uuidValue(body.submissionId, "submissionId");
  const installationId = uuidValue(body.installationId, "installationId");
  const displayName = publicText(body.displayName, "displayName", 40, 120);
  const processorModel = publicText(
    body.processorModel,
    "processorModel",
    80,
    240,
  );
  const profile = profileValue(body.profile);
  const requestedWorkload = workloadValue(body.workloadVersion);
  requireMatchingProfile(profile, requestedWorkload);

  // Parse repeatability evidence before the activation policy so the pure
  // validator enforces the complete v6 protocol.
  const metricsObject = objectValue(body.metrics, "metrics");
  const metrics = Object.fromEntries(
    METRIC_KEYS.map((key) => [key, finiteNumber(metricsObject[key], `metrics.${key}`)]),
  ) as unknown as BenchmarkMetrics;
  const physicalMemoryBytes = optionalPositiveSafeInteger(
    metricsObject.physicalMemoryBytes,
    "metrics.physicalMemoryBytes",
  );
  const systemDiskCapacityBytes = optionalPositiveSafeInteger(
    metricsObject.systemDiskCapacityBytes,
    "metrics.systemDiskCapacityBytes",
  );
  const stability = validateMetricStabilityEvidence(
    requestedWorkload,
    metricsObject.stability,
  );
  if (requestedWorkload === "mac-benchmark-standard-v6") {
    if (physicalMemoryBytes === undefined) {
      throw new SubmissionValidationError("metrics.physicalMemoryBytes");
    }
    if (systemDiskCapacityBytes === undefined) {
      throw new SubmissionValidationError("metrics.systemDiskCapacityBytes");
    }
  }
  if (physicalMemoryBytes !== undefined) {
    metrics.physicalMemoryBytes = physicalMemoryBytes;
  }
  if (systemDiskCapacityBytes !== undefined) {
    metrics.systemDiskCapacityBytes = systemDiskCapacityBytes;
  }
  if (stability !== undefined) {
    metrics.stability = stability;
  }

  const workloadVersion = activatedSubmissionWorkload(
    profile,
    requestedWorkload,
  );
  const baselineVersion = BASELINE_BY_WORKLOAD[workloadVersion];
  if (body.baselineVersion !== baselineVersion) {
    throw new SubmissionValidationError("baselineVersion");
  }
  if (body.architecture !== "arm64") {
    throw new SubmissionValidationError("architecture");
  }

  const completedAtDate = dateValue(body.completedAt, "completedAt");
  const earliest = now.getTime() - 30 * 24 * 60 * 60 * 1_000;
  const latest = now.getTime() + 5 * 60 * 1_000;
  if (
    completedAtDate.getTime() < earliest ||
    completedAtDate.getTime() > latest
  ) {
    throw new SubmissionValidationError("completedAt");
  }

  const appVersion = textValue(body.appVersion, "appVersion", 24);
  if (!isAtLeastVersion(
    appVersion,
    MINIMUM_SOURCE_APP_VERSION_BY_WORKLOAD[workloadVersion],
  )) {
    throw new SubmissionValidationError("appVersion", "incompatible_source_version");
  }
  const appBuild = textValue(body.appBuild, "appBuild", 20);
  if (!APP_BUILD_PATTERN.test(appBuild)) {
    throw new SubmissionValidationError("appBuild");
  }

  const conditions = objectValue(body.conditions, "conditions");
  if (
    conditions.powerSource !== "acPower" ||
    conditions.lowPowerModeEnabled !== false ||
    conditions.preflightThermalState !== "nominal" ||
    conditions.postflightThermalState !== "nominal"
  ) {
    throw new SubmissionValidationError("conditions");
  }

  const reference = REFERENCE_METRICS[workloadVersion];
  for (const key of METRIC_KEYS) {
    const ratio = metrics[key] / reference[key];
    if (ratio < 0.02 || ratio > 5) {
      throw new SubmissionValidationError(`metrics.${key}`);
    }
  }

  const proposedScore = finiteNumber(body.proposedScore, "proposedScore");
  const recomputedScore = computeScore(workloadVersion, metrics);
  if (Math.abs(proposedScore - recomputedScore) > 1) {
    throw new SubmissionValidationError("proposedScore", "score_mismatch");
  }

  return {
    submissionId,
    installationId,
    displayName,
    processorModel,
    profile,
    workloadVersion,
    baselineVersion,
    architecture: "arm64",
    completedAt: completedAtDate.toISOString(),
    appVersion,
    appBuild,
    conditions: {
      powerSource: "acPower",
      lowPowerModeEnabled: false,
      preflightThermalState: "nominal",
      postflightThermalState: "nominal",
    },
    metrics,
    proposedScore: recomputedScore,
  };
}

export function validateDeletion(value: unknown): DeletionRequest {
  const body = objectValue(value, "body");
  const installationId = uuidValue(body.installationId, "installationId");
  const profile = profileValue(body.profile);
  const workloadVersion = workloadValue(body.workloadVersion);
  requireMatchingProfile(profile, workloadVersion);
  if (!containsWorkload(DELETABLE_WORKLOADS_BY_PROFILE[profile], workloadVersion)) {
    throw new SubmissionValidationError("workloadVersion");
  }
  return { installationId, profile, workloadVersion };
}

function workloadValue(value: unknown): WorkloadVersion {
  if (!isKnownWorkloadVersion(value)) {
    throw new SubmissionValidationError("workloadVersion");
  }
  return value;
}

function requireMatchingProfile(
  profile: BenchmarkProfile,
  workloadVersion: WorkloadVersion,
): void {
  if (PROFILE_BY_WORKLOAD[workloadVersion] !== profile) {
    throw new SubmissionValidationError("workloadVersion");
  }
}

function containsWorkload(
  values: readonly WorkloadVersion[],
  workloadVersion: WorkloadVersion,
): boolean {
  return values.includes(workloadVersion);
}

function activatedSubmissionWorkload(
  profile: BenchmarkProfile,
  requestedWorkload: WorkloadVersion,
): FrozenWorkloadVersion {
  if (
    !containsWorkload(
      ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE[profile],
      requestedWorkload,
    )
    || !isFrozenWorkloadVersion(requestedWorkload)
  ) {
    throw new SubmissionValidationError(
      "workloadVersion",
      "unsupported_workload_version",
    );
  }
  return requestedWorkload;
}

function objectValue(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new SubmissionValidationError(field);
  }
  return value as Record<string, unknown>;
}

function uuidValue(value: unknown, field: string): string {
  const text = textValue(value, field, 36).toLowerCase();
  if (!UUID_PATTERN.test(text)) {
    throw new SubmissionValidationError(field);
  }
  return text;
}

function profileValue(value: unknown): BenchmarkProfile {
  if (value !== "standard" && value !== "quick" && value !== "full") {
    throw new SubmissionValidationError("profile");
  }
  return value;
}

function publicText(
  value: unknown,
  field: string,
  maxCharacters: number,
  maxBytes: number,
): string {
  const text = textValue(value, field, maxBytes)
    .normalize("NFKC")
    .trim()
    .replace(/\s+/gu, " ");
  if (
    text.length === 0 ||
    Array.from(text).length > maxCharacters ||
    new TextEncoder().encode(text).byteLength > maxBytes ||
    CONTROL_CHARACTER_PATTERN.test(text)
  ) {
    throw new SubmissionValidationError(field);
  }
  return text;
}

function textValue(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new SubmissionValidationError(field);
  }
  return value;
}

function finiteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new SubmissionValidationError(field);
  }
  return value;
}

function nonNegativeFiniteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new SubmissionValidationError(field);
  }
  return value;
}

function positiveSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new SubmissionValidationError(field);
  }
  return value;
}

function optionalPositiveSafeInteger(
  value: unknown,
  field: string,
): number | undefined {
  if (value === undefined) return undefined;
  return positiveSafeInteger(value, field);
}

function dateValue(value: unknown, field: string): Date {
  const text = textValue(value, field, 40);
  const date = new Date(text);
  if (!Number.isFinite(date.getTime())) {
    throw new SubmissionValidationError(field);
  }
  return date;
}

function isAtLeastVersion(value: string, minimum: string): boolean {
  const parse = (version: string): [number, number, number] | null => {
    const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(version);
    if (!match) return null;
    return [Number(match[1]), Number(match[2]), Number(match[3])];
  };
  const current = parse(value);
  const required = parse(minimum);
  if (!current || !required) return false;
  for (let index = 0; index < 3; index += 1) {
    const currentPart = current[index] ?? 0;
    const requiredPart = required[index] ?? 0;
    if (currentPart !== requiredPart) return currentPart > requiredPart;
  }
  return true;
}
