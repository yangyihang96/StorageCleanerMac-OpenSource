import {
  V2_CATEGORY_WEIGHTS,
  V2_CORE_METRICS,
  V2_DISPLAY_BASELINE,
  V2_MAX_METRIC_RATIO,
  V2_MAX_PUBLIC_SCORE,
  V2_PLAN_VERSION,
  V2_REFERENCE_SET_VERSION,
  V2_SCORING_VERSION,
  V2_WORKLOAD_VERSION,
  type V2CoreCategory,
  type V2DeletionRequest,
  type V2Metrics,
  type V2ValidatedSubmission,
} from "./v2-contracts";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const APP_VERSION_PATTERN = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
const APP_BUILD_PATTERN = /^\d{8,20}$/;
const ISO_DATE_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/u;
const CORE_CATEGORIES: readonly V2CoreCategory[] = [
  "cpu",
  "gpu",
  "memory",
  "storage",
];
const TOP_LEVEL_FIELDS = [
  "submissionId",
  "installationId",
  "displayName",
  "computerModel",
  "processorModel",
  "memoryGB",
  "architecture",
  "planVersion",
  "workloadVersion",
  "scoringVersion",
  "referenceSetVersion",
  "completedAt",
  "appVersion",
  "appBuild",
  "conditions",
  "metrics",
  "proposedScore",
] as const;
const CONDITION_FIELDS = [
  "powerSource",
  "lowPowerModeEnabled",
  "thermalState",
  "confidence",
  "sustainedReachedTargetDuration",
] as const;
const DELETION_FIELDS = ["installationId", "workloadVersion"] as const;

export class V2ValidationError extends Error {
  constructor(
    readonly field: string,
    readonly code = "invalid_submission",
  ) {
    super(`Invalid v2 leaderboard field: ${field}`);
  }
}

export function computeV2CoreScore(metrics: V2Metrics): number {
  const categoryRatios: Array<{ value: number; weight: number }> = [];
  for (const category of CORE_CATEGORIES) {
    const ratios = V2_CORE_METRICS
      .filter((metric) => metric.category === category)
      .map((metric) => {
        const measured = metrics[metric.id];
        let ratio = metric.direction === "higherIsBetter"
          ? measured / metric.reference
          : metric.reference / measured;
        if (!Number.isFinite(ratio) || ratio <= 0) {
          throw new V2ValidationError(`metrics.${metric.id}`);
        }
        if (ratio > V2_MAX_METRIC_RATIO * (1 + 1e-12)) {
          throw new V2ValidationError(
            `metrics.${metric.id}`,
            "metric_out_of_range",
          );
        }
        if (ratio > V2_MAX_METRIC_RATIO) ratio = V2_MAX_METRIC_RATIO;
        return { value: ratio, weight: metric.weight };
      });
    categoryRatios.push({
      value: weightedGeometricMean(ratios),
      weight: V2_CATEGORY_WEIGHTS[category],
    });
  }
  const score = V2_DISPLAY_BASELINE * weightedGeometricMean(categoryRatios);
  if (
    !Number.isFinite(score)
    || score <= 0
    || score > V2_MAX_PUBLIC_SCORE
  ) {
    throw new V2ValidationError("metrics");
  }
  return score;
}

export function validateV2Submission(
  value: unknown,
  now = new Date(),
  enforceCompletionWindow = true,
): V2ValidatedSubmission {
  const body = objectValue(value, "body");
  assertExactKeys(body, TOP_LEVEL_FIELDS, "body");

  const submissionId = uuidValue(body.submissionId, "submissionId");
  const installationId = uuidValue(body.installationId, "installationId");
  const displayName = publicText(body.displayName, "displayName", 40, 120);
  const computerModel = publicText(body.computerModel, "computerModel", 80, 240);
  const processorModel = publicText(
    body.processorModel,
    "processorModel",
    80,
    240,
  );
  const memoryGB = positiveSafeInteger(body.memoryGB, "memoryGB");
  if (memoryGB > 2_048) throw new V2ValidationError("memoryGB");
  if (body.architecture !== "arm64") {
    throw new V2ValidationError("architecture");
  }
  requireVersion(body.planVersion, V2_PLAN_VERSION, "planVersion");
  requireVersion(body.workloadVersion, V2_WORKLOAD_VERSION, "workloadVersion");
  requireVersion(body.scoringVersion, V2_SCORING_VERSION, "scoringVersion");
  requireVersion(
    body.referenceSetVersion,
    V2_REFERENCE_SET_VERSION,
    "referenceSetVersion",
  );

  const completedAtDate = isoDateValue(body.completedAt, "completedAt");
  if (enforceCompletionWindow) {
    assertV2CompletionWindow(completedAtDate, now);
  }
  const completedAt = completedAtDate.toISOString();
  const completedOn = completedAt.slice(0, 10);

  const appVersion = textValue(body.appVersion, "appVersion", 32);
  if (!APP_VERSION_PATTERN.test(appVersion)) {
    throw new V2ValidationError("appVersion");
  }
  const appBuild = textValue(body.appBuild, "appBuild", 20);
  if (!APP_BUILD_PATTERN.test(appBuild)) {
    throw new V2ValidationError("appBuild");
  }

  const conditions = objectValue(body.conditions, "conditions");
  assertExactKeys(conditions, CONDITION_FIELDS, "conditions");
  if (
    conditions.powerSource !== "acPower"
    || conditions.lowPowerModeEnabled !== false
    || conditions.thermalState !== "nominal"
    || (conditions.confidence !== "high"
        && conditions.confidence !== "medium"
        && conditions.confidence !== "low")
    || conditions.sustainedReachedTargetDuration !== true
  ) {
    throw new V2ValidationError("conditions");
  }

  const metricsObject = objectValue(body.metrics, "metrics");
  const expectedMetricIDs = V2_CORE_METRICS.map((metric) => metric.id);
  assertExactKeys(metricsObject, expectedMetricIDs, "metrics");
  const metrics = Object.fromEntries(V2_CORE_METRICS.map((metric) => [
    metric.id,
    positiveFiniteNumber(metricsObject[metric.id], `metrics.${metric.id}`),
  ])) as V2Metrics;
  const proposedScore = positiveFiniteNumber(body.proposedScore, "proposedScore");
  const recomputedScore = computeV2CoreScore(metrics);
  if (Math.abs(proposedScore - recomputedScore) > 1) {
    throw new V2ValidationError("proposedScore", "score_mismatch");
  }

  return {
    submissionId,
    installationId,
    displayName,
    computerModel,
    processorModel,
    memoryGB,
    architecture: "arm64",
    planVersion: V2_PLAN_VERSION,
    workloadVersion: V2_WORKLOAD_VERSION,
    scoringVersion: V2_SCORING_VERSION,
    referenceSetVersion: V2_REFERENCE_SET_VERSION,
    completedAt,
    completedOn,
    appVersion,
    appBuild,
    conditions: {
      powerSource: "acPower",
      lowPowerModeEnabled: false,
      thermalState: "nominal",
      confidence: conditions.confidence,
      sustainedReachedTargetDuration: true,
    },
    metrics,
    proposedScore: recomputedScore,
  };
}

export function assertV2SubmissionFresh(
  submission: Pick<V2ValidatedSubmission, "completedAt">,
  now = new Date(),
): void {
  const completedAt = isoDateValue(submission.completedAt, "completedAt");
  assertV2CompletionWindow(completedAt, now);
}

export function validateV2Deletion(value: unknown): V2DeletionRequest {
  const body = objectValue(value, "body");
  assertExactKeys(body, DELETION_FIELDS, "body");
  const installationId = uuidValue(body.installationId, "installationId");
  requireVersion(body.workloadVersion, V2_WORKLOAD_VERSION, "workloadVersion");
  return { installationId, workloadVersion: V2_WORKLOAD_VERSION };
}

export function canonicalV2Submission(
  submission: V2ValidatedSubmission,
  installationHash: string,
): string {
  return JSON.stringify({
    submissionId: submission.submissionId,
    installationHash,
    displayName: submission.displayName,
    computerModel: submission.computerModel,
    processorModel: submission.processorModel,
    memoryGB: submission.memoryGB,
    architecture: submission.architecture,
    planVersion: submission.planVersion,
    workloadVersion: submission.workloadVersion,
    scoringVersion: submission.scoringVersion,
    referenceSetVersion: submission.referenceSetVersion,
    completedAt: submission.completedAt,
    appVersion: submission.appVersion,
    appBuild: submission.appBuild,
    conditions: submission.conditions,
    metrics: Object.fromEntries(V2_CORE_METRICS.map((metric) => [
      metric.id,
      submission.metrics[metric.id],
    ])),
    proposedScore: submission.proposedScore,
  });
}

function weightedGeometricMean(
  values: ReadonlyArray<{ value: number; weight: number }>,
): number {
  if (values.length === 0) throw new V2ValidationError("metrics");
  let weightedLog = 0;
  let totalWeight = 0;
  for (const value of values) {
    if (
      !Number.isFinite(value.value)
      || value.value <= 0
      || !Number.isFinite(value.weight)
      || value.weight <= 0
    ) {
      throw new V2ValidationError("metrics");
    }
    weightedLog += value.weight * Math.log(value.value);
    totalWeight += value.weight;
  }
  const result = Math.exp(weightedLog / totalWeight);
  if (!Number.isFinite(result) || result <= 0) {
    throw new V2ValidationError("metrics");
  }
  // A geometric mean is mathematically inside its input range. Keep floating
  // point round-off from crossing the exact public ceiling at the boundary.
  const minimum = Math.min(...values.map((value) => value.value));
  const maximum = Math.max(...values.map((value) => value.value));
  return Math.max(minimum, Math.min(maximum, result));
}

function objectValue(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new V2ValidationError(field);
  }
  return value as Record<string, unknown>;
}

function assertExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
  field: string,
): void {
  const actual = Object.keys(value).sort();
  const required = [...expected].sort();
  if (
    actual.length !== required.length
    || actual.some((key, index) => key !== required[index])
  ) {
    throw new V2ValidationError(field);
  }
}

function uuidValue(value: unknown, field: string): string {
  const text = textValue(value, field, 36).toLowerCase();
  if (!UUID_PATTERN.test(text)) throw new V2ValidationError(field);
  return text;
}

function publicText(
  value: unknown,
  field: string,
  maximumCharacters: number,
  maximumBytes: number,
): string {
  const text = textValue(value, field, maximumBytes)
    .normalize("NFKC")
    .trim()
    .replace(/\s+/gu, " ");
  if (
    text.length === 0
    || Array.from(text).length > maximumCharacters
    || new TextEncoder().encode(text).byteLength > maximumBytes
    || CONTROL_CHARACTER_PATTERN.test(text)
  ) {
    throw new V2ValidationError(field);
  }
  return text;
}

function textValue(value: unknown, field: string, maximumLength: number): string {
  if (
    typeof value !== "string"
    || value.length === 0
    || value.length > maximumLength
  ) {
    throw new V2ValidationError(field);
  }
  return value;
}

function positiveFiniteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new V2ValidationError(field);
  }
  return value;
}

function positiveSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new V2ValidationError(field);
  }
  return value;
}

function isoDateValue(value: unknown, field: string): Date {
  const text = textValue(value, field, 40);
  if (!ISO_DATE_PATTERN.test(text)) throw new V2ValidationError(field);
  const date = new Date(text);
  if (
    !Number.isFinite(date.getTime())
    || date.toISOString().slice(0, 19) !== text.slice(0, 19)
  ) throw new V2ValidationError(field);
  return date;
}

function assertV2CompletionWindow(completedAt: Date, now: Date): void {
  const earliest = now.getTime() - 30 * 24 * 60 * 60 * 1_000;
  const latest = now.getTime() + 5 * 60 * 1_000;
  if (completedAt.getTime() < earliest || completedAt.getTime() > latest) {
    throw new V2ValidationError("completedAt");
  }
}

function requireVersion(
  value: unknown,
  expected: string,
  field: string,
): void {
  if (value !== expected) {
    throw new V2ValidationError(field, "unsupported_version");
  }
}
