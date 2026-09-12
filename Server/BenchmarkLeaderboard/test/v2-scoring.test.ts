import { describe, expect, it } from "vitest";
import {
  V2_CORE_METRICS,
  V2_MAX_METRIC_RATIO,
  V2_MAX_PUBLIC_SCORE,
  V2_PLAN_VERSION,
  V2_REFERENCE_SET_VERSION,
  V2_SCORING_VERSION,
  V2_WORKLOAD_VERSION,
  type V2Metrics,
} from "../src/v2-contracts";
import {
  V2ValidationError,
  computeV2CoreScore,
  validateV2Submission,
} from "../src/v2-scoring";

const now = new Date("2026-08-05T02:00:00.000Z");

describe("V7 v2 scoring contract", () => {
  it("matches the 21-metric controlled reference at 6000", () => {
    expect(V2_CORE_METRICS).toHaveLength(21);
    expect(computeV2CoreScore(referenceMetrics())).toBeCloseTo(6_000, 10);
  });

  it("uses both metric and category weighted geometric means", () => {
    const ratios = ratioMetrics(2);
    expect(computeV2CoreScore(ratios)).toBeCloseTo(12_000, 8);
  });

  it("rejects the 200x all-metric score amplification attack", () => {
    expect(() => computeV2CoreScore(ratioMetrics(200))).toThrowError(
      expect.objectContaining<Partial<V2ValidationError>>({
        field: "metrics.cpu.single.mixed",
        code: "metric_out_of_range",
      }),
    );
  });

  it("accepts the mathematically bounded maximum without exceeding the public cap", () => {
    const score = computeV2CoreScore(ratioMetrics(V2_MAX_METRIC_RATIO));
    expect(score).toBe(V2_MAX_PUBLIC_SCORE);
  });

  it("accepts only the complete, exact v9 request and recomputes its score", () => {
    const request = validV2Submission();
    request.displayName = "  匿名\nMac  ";
    const submission = validateV2Submission(request, now);
    expect(submission.displayName).toBe("匿名 Mac");
    expect(submission.completedOn).toBe("2026-08-05");
    expect(submission.proposedScore).toBeCloseTo(6_000, 10);
  });

  it.each(["missing", "extra"])(
    "rejects %s core metrics instead of reweighting",
    (mode) => {
      const request = validV2Submission();
      if (mode === "missing") {
        delete (request.metrics as Partial<V2Metrics>)["cpu.single.mixed"];
      } else {
        (request.metrics as Record<string, number>)["display.cadence.p95.ms"] = 10;
      }
      expect(() => validateV2Submission(request, now)).toThrowError(
        expect.objectContaining<Partial<V2ValidationError>>({ field: "metrics" }),
      );
    },
  );

  it("rejects invalid metric values and a client-controlled score", () => {
    const invalidMetric = validV2Submission();
    invalidMetric.metrics["gpu.compute.fp16"] = Number.POSITIVE_INFINITY;
    expect(() => validateV2Submission(invalidMetric, now)).toThrowError(
      expect.objectContaining<Partial<V2ValidationError>>({
        field: "metrics.gpu.compute.fp16",
      }),
    );

    const mismatch = validV2Submission();
    mismatch.proposedScore = 9_999;
    expect(() => validateV2Submission(mismatch, now)).toThrowError(
      expect.objectContaining<Partial<V2ValidationError>>({
        field: "proposedScore",
        code: "score_mismatch",
      }),
    );
  });

  it.each([
    ["planVersion", "benchmark-standard-plan-v8"],
    ["workloadVersion", "benchmark-standard-v8"],
    ["scoringVersion", "benchmark-scoring-v8"],
    ["referenceSetVersion", "local-m5-pro-controlled-v8-r1"],
  ])("rejects an incompatible %s", (field, value) => {
    const request = validV2Submission() as unknown as Record<string, unknown>;
    request[field] = value;
    expect(() => validateV2Submission(request, now)).toThrowError(
      expect.objectContaining<Partial<V2ValidationError>>({
        field,
        code: "unsupported_version",
      }),
    );
  });

  it.each([
    ["powerSource", "battery"],
    ["lowPowerModeEnabled", true],
    ["thermalState", "fair"],
    ["sustainedReachedTargetDuration", false],
  ])("rejects ineligible condition %s", (field, value) => {
    const request = validV2Submission();
    (request.conditions as unknown as Record<string, unknown>)[field] = value;
    expect(() => validateV2Submission(request, now)).toThrowError(
      expect.objectContaining<Partial<V2ValidationError>>({ field: "conditions" }),
    );
  });

  it("accepts low-confidence submissions and preserves the rating", () => {
    const request = validV2Submission();
    request.conditions.confidence = "low";
    const validated = validateV2Submission(request, now);
    expect(validated.conditions.confidence).toBe("low");
  });
});

export function referenceMetrics(): V2Metrics {
  return Object.fromEntries(
    V2_CORE_METRICS.map((metric) => [metric.id, metric.reference]),
  ) as V2Metrics;
}

export function ratioMetrics(ratio: number): V2Metrics {
  return Object.fromEntries(V2_CORE_METRICS.map((metric) => [
    metric.id,
    metric.direction === "higherIsBetter"
      ? metric.reference * ratio
      : metric.reference / ratio,
  ])) as V2Metrics;
}

export function validV2Submission() {
  return {
    submissionId: "123e4567-e89b-42d3-a456-426614174000",
    installationId: "123e4567-e89b-42d3-a456-426614174001",
    displayName: "匿名 Mac 001",
    computerModel: "Mac17,9",
    processorModel: "Apple M5 Pro",
    memoryGB: 48,
    architecture: "arm64",
    planVersion: V2_PLAN_VERSION,
    workloadVersion: V2_WORKLOAD_VERSION,
    scoringVersion: V2_SCORING_VERSION,
    referenceSetVersion: V2_REFERENCE_SET_VERSION,
    completedAt: "2026-08-05T01:30:00.000Z",
    appVersion: "1.9.9",
    appBuild: "202608051049",
    conditions: {
      powerSource: "acPower",
      lowPowerModeEnabled: false,
      thermalState: "nominal",
      confidence: "high",
      sustainedReachedTargetDuration: true,
    },
    metrics: referenceMetrics(),
    proposedScore: 6_000,
  };
}
