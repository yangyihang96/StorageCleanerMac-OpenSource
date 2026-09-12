import { describe, expect, it } from "vitest";
import {
  ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE,
  ACTIVE_WORKLOAD_BY_PROFILE,
  BASELINE_BY_WORKLOAD,
  FROZEN_WORKLOAD_VERSIONS,
  QUERYABLE_WORKLOADS_BY_PROFILE,
  REFERENCE_METRICS,
  type BenchmarkMetrics,
  type BenchmarkProfile,
  type BenchmarkStabilityEvidence,
  type FrozenWorkloadVersion,
  type WorkloadVersion,
} from "../src/contracts";
import {
  SubmissionValidationError,
  V6_BALANCED_WEIGHTS,
  V6_MAXIMUM_PERFORMANCE_RATIO,
  V6_MINIMUM_PERFORMANCE_RATIO,
  V6_MAXIMUM_COEFFICIENT_OF_VARIATION,
  V6_REFERENCE_PHYSICAL_MEMORY_BYTES,
  V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES,
  V6_REFERENCE_TOTAL_SCORE,
  V6_REQUIRED_SAMPLE_COUNT,
  computeScore,
  computeV6BalancedCompositeScore,
  validateDeletion,
  validateMetricStabilityEvidence,
  validateSubmission,
  type BenchmarkMetricRatios,
} from "../src/scoring";

const now = new Date("2026-07-17T06:00:00.000Z");

describe("benchmark leaderboard scoring", () => {
  it("activates only the Standard v6 public contract", () => {
    expect(ACTIVE_WORKLOAD_BY_PROFILE.standard).toBe("mac-benchmark-standard-v6");
    expect(ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE.standard).toEqual([
      "mac-benchmark-standard-v6",
    ]);
    expect(QUERYABLE_WORKLOADS_BY_PROFILE.standard).toEqual([
      "mac-benchmark-standard-v6",
    ]);
    for (const profile of ["quick", "full"] as const) {
      expect(ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE[profile]).toEqual([]);
      expect(QUERYABLE_WORKLOADS_BY_PROFILE[profile]).toEqual([]);
      expect(ACCEPTED_SUBMISSION_WORKLOADS_BY_PROFILE[profile])
        .not.toContain(ACTIVE_WORKLOAD_BY_PROFILE[profile]);
    }
  });

  it.each(FROZEN_WORKLOAD_VERSIONS)(
    "maps the genuinely frozen %s reference to 6000",
    (workload) => {
      expect(computeScore(workload, REFERENCE_METRICS[workload])).toBeCloseTo(
        6_000,
        8,
      );
    },
  );

  it("keeps v5 out and activates the independently frozen v6 maps", () => {
    expect(REFERENCE_METRICS).not.toHaveProperty("mac-benchmark-standard-v5");
    expect(BASELINE_BY_WORKLOAD).not.toHaveProperty("mac-benchmark-standard-v5");
    expect(REFERENCE_METRICS["mac-benchmark-standard-v6"]).toMatchObject({
      cpuSingle: 420.57305150435,
      physicalMemoryBytes: V6_REFERENCE_PHYSICAL_MEMORY_BYTES,
      systemDiskCapacityBytes: V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES,
    });
    expect(BASELINE_BY_WORKLOAD["mac-benchmark-standard-v6"])
      .toBe("m5-pro-2026-07-v6");
  });

  it("preserves the frozen v3/v4 per-component clamp", () => {
    const reference = REFERENCE_METRICS["mac-benchmark-standard-v4"];
    const metrics = Object.fromEntries(
      Object.entries(reference).map(([key, value]) => [key, value * 0.1]),
    ) as unknown as BenchmarkMetrics;
    expect(computeScore("mac-benchmark-standard-v4", metrics)).toBeCloseTo(
      1_200,
      8,
    );
  });

  it("keeps optional capacity metadata out of the frozen v3/v4 score", () => {
    const reference = REFERENCE_METRICS["mac-benchmark-standard-v4"];
    const enriched = {
      ...reference,
      physicalMemoryBytes: 51_539_607_552,
      systemDiskCapacityBytes: 994_610_155_520,
    } satisfies BenchmarkMetrics;
    expect(computeScore("mac-benchmark-standard-v4", enriched)).toBeCloseTo(
      computeScore("mac-benchmark-standard-v4", reference),
      12,
    );
  });
});

describe("proposed v6 balanced-composite formula", () => {
  it("has golden weights that sum to one and maps unit ratios to 6000", () => {
    expect(Object.values(V6_BALANCED_WEIGHTS).reduce((sum, value) => sum + value, 0))
      .toBeCloseTo(1, 12);
    expect(V6_REFERENCE_TOTAL_SCORE).toBe(6_000);
    expect(computeV6BalancedCompositeScore(unitRatios(), referenceCapacity()))
      .toBeCloseTo(6_000, 10);
  });

  it("combines uniform 2x throughput with reference capacity", () => {
    const expected = 6_000
      * Math.pow(2, 0.14 + 0.21 + 0.25)
      * Math.pow(1.75, 0.20)
      * Math.pow(1.9, 0.11 + 0.09);
    expect(computeV6BalancedCompositeScore(
      uniformRatios(2),
      referenceCapacity(),
    )).toBeCloseTo(
      expected,
      10,
    );
  });

  it("applies the golden exponent for an isolated component improvement", () => {
    const ratios = unitRatios();
    ratios.cpuSingle = 2;
    expect(computeV6BalancedCompositeScore(ratios, referenceCapacity())).toBeCloseTo(
      6_000 * Math.pow(2, 0.14),
      10,
    );
  });

  it("accepts the inclusive ratio bounds without clamping", () => {
    expect(V6_MINIMUM_PERFORMANCE_RATIO).toBe(0.02);
    expect(V6_MAXIMUM_PERFORMANCE_RATIO).toBe(5);
    expect(() => computeV6BalancedCompositeScore(
      uniformRatios(0.02),
      referenceCapacity(),
    )).not.toThrow();
    expect(() => computeV6BalancedCompositeScore(
      uniformRatios(5),
      referenceCapacity(),
    )).not.toThrow();
  });

  it("includes bounded memory and disk capacity", () => {
    const ratios = unitRatios();
    expect(Object.keys(ratios)).toEqual([
      "cpuSingle",
      "cpuMulti",
      "gpu",
      "memory",
      "diskRead",
      "diskWrite",
    ]);
    const quarterCapacity = {
      physicalMemoryBytes: V6_REFERENCE_PHYSICAL_MEMORY_BYTES / 4,
      systemDiskCapacityBytes: V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES / 4,
    };
    const expected = 6_000 * Math.pow(0.875, 0.20) * Math.pow(0.95, 0.20);
    expect(computeV6BalancedCompositeScore(ratios, quarterCapacity)).toBeCloseTo(
      expected,
      10,
    );
    expect(expected).toBeLessThan(6_000);
  });

  it.each([0.019_999, 5.000_001, 0, Number.NaN, Number.POSITIVE_INFINITY])(
    "rejects an invalid ratio of %s instead of clamping it",
    (invalidRatio) => {
      const ratios = unitRatios();
      ratios.gpu = invalidRatio;
      expect(() => computeV6BalancedCompositeScore(
        ratios,
        referenceCapacity(),
      )).toThrow(RangeError);
    },
  );

  it.each([0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY])(
    "rejects invalid capacity %s",
    (invalidCapacity) => {
      expect(() => computeV6BalancedCompositeScore(unitRatios(), {
        physicalMemoryBytes: invalidCapacity,
        systemDiskCapacityBytes: V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES,
      })).toThrow(RangeError);
    },
  );
});

describe("submission validation", () => {
  it("normalizes public text and returns the frozen v6 server score", () => {
    const request = validStandardRequest();
    request.displayName = "  工作室\nMac  ";
    request.metrics.physicalMemoryBytes = 51_539_607_552;
    request.metrics.systemDiskCapacityBytes = 994_610_155_520;
    const result = validateSubmission(request, now);
    expect(result.displayName).toBe("工作室 Mac");
    expect(result.workloadVersion).toBe("mac-benchmark-standard-v6");
    expect(result.baselineVersion).toBe("m5-pro-2026-07-v6");
    expect(result.metrics.physicalMemoryBytes).toBe(51_539_607_552);
    expect(result.metrics.systemDiskCapacityBytes).toBe(994_610_155_520);
    expect(result.proposedScore).toBeCloseTo(6_000, 8);
  });

  it("keeps frozen v4 scoring available but rejects v4 as a public submission", () => {
    expect(() => validateSubmission(validStandardV4Request(), now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "workloadVersion",
        code: "unsupported_workload_version",
      }),
    );
  });

  it.each([
    0,
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    null,
  ])("rejects invalid optional capacity metadata value %s", (invalidValue) => {
    for (const field of [
      "physicalMemoryBytes",
      "systemDiskCapacityBytes",
    ] as const) {
      const request = validStandardRequest();
      (request.metrics as unknown as Record<string, unknown>)[field] = invalidValue;
      expect(() => validateSubmission(request, now)).toThrowError(
        expect.objectContaining<Partial<SubmissionValidationError>>({
          field: `metrics.${field}`,
        }),
      );
    }
  });

  it("rejects workload/profile mismatches", () => {
    const request = validStandardRequest();
    request.workloadVersion = "mac-benchmark-full-v3";
    expect(() => validateSubmission(request, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "workloadVersion",
        code: "invalid_submission",
      }),
    );
  });

  it.each([
    "mac-benchmark-standard-v5",
  ] satisfies WorkloadVersion[])(
    "rejects uncalibrated %s submissions with an explicit protocol error",
    (workloadVersion) => {
      const request = validStandardRequest();
      request.workloadVersion = workloadVersion;
      request.baselineVersion = `unfrozen-${workloadVersion}`;
      expect(() => validateSubmission(request, now)).toThrowError(
        expect.objectContaining<Partial<SubmissionValidationError>>({
          field: "workloadVersion",
          code: "unsupported_workload_version",
        }),
      );
    },
  );

  it("requires complete repeatability evidence for the active v6 protocol", () => {
    const request = validStandardRequest();
    delete request.metrics.stability;
    expect(() => validateSubmission(request, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "metrics.stability",
      }),
    );
  });

  it("requires both capacity inputs for the active v6 protocol", () => {
    for (const field of [
      "physicalMemoryBytes",
      "systemDiskCapacityBytes",
    ] as const) {
      const request = validStandardRequest();
      delete request.metrics[field];
      expect(() => validateSubmission(request, now)).toThrowError(
        expect.objectContaining<Partial<SubmissionValidationError>>({
          field: `metrics.${field}`,
        }),
      );
    }
  });

  it("rejects an active v6 run whose medians are legal but GPU CV is over 10%", () => {
    const request = validStandardRequest();
    request.metrics.stability!.gpu.coefficientOfVariation = 0.100_001;

    expect(() => validateSubmission(request, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "metrics.stability.gpu.coefficientOfVariation",
      }),
    );
  });

  it("requires exactly three samples for every active v6 component", () => {
    const request = validStandardRequest();
    request.metrics.stability!.diskRead.sampleCount = 2;

    expect(() => validateSubmission(request, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "metrics.stability.diskRead.sampleCount",
      }),
    );
  });

  it("accepts every inclusive v6 CV endpoint in the protocol validator", () => {
    const evidence = stabilityEvidence(0, V6_REQUIRED_SAMPLE_COUNT);
    for (const [key, limit] of Object.entries(
      V6_MAXIMUM_COEFFICIENT_OF_VARIATION,
    )) {
      evidence[key as keyof BenchmarkStabilityEvidence].coefficientOfVariation = limit;
    }

    expect(validateMetricStabilityEvidence(
      "mac-benchmark-standard-v6",
      evidence,
    )).toEqual(evidence);
  });

  it("rejects client scores that differ from the frozen calculation", () => {
    const request = validStandardRequest();
    request.proposedScore = 9_999;
    expect(() => validateSubmission(request, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        code: "score_mismatch",
      }),
    );
  });

  it("accepts Standard v6 from 1.8.2 and rejects older sources and stale results", () => {
    expect(validateSubmission(validStandardRequest(), now).appVersion).toBe("1.8.2");

    const oldClient = validStandardRequest();
    oldClient.appVersion = "1.8.1";
    expect(() => validateSubmission(oldClient, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        code: "incompatible_source_version",
      }),
    );

    const stale = validStandardRequest();
    stale.completedAt = "2026-05-01T00:00:00.000Z";
    expect(() => validateSubmission(stale, now)).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "completedAt",
      }),
    );
  });

  it.each([
    ["standard", "mac-benchmark-standard-v4", "m5-pro-2026-07-v4", "1.8.2"],
    ["quick", "mac-benchmark-quick-v3", "m5-pro-2026-07-v3", "1.6.1"],
    ["full", "mac-benchmark-full-v3", "m5-pro-2026-07-v3", "1.6.1"],
  ] satisfies Array<[
    BenchmarkProfile,
    FrozenWorkloadVersion,
    string,
    string,
  ]>)(
    "rejects legacy %s / %s public uploads",
    (profile, workloadVersion, baselineVersion, appVersion) => {
      const legacy = validRequestFor(
        profile,
        workloadVersion,
        baselineVersion,
        appVersion,
      );
      expect(() => validateSubmission(legacy, now)).toThrowError(
        expect.objectContaining<Partial<SubmissionValidationError>>({
          field: "workloadVersion",
          code: "unsupported_workload_version",
        }),
      );
    },
  );
});

describe("deletion validation", () => {
  it.each([
    ["standard", "mac-benchmark-standard-v4"],
    ["standard", "mac-benchmark-standard-v5"],
    ["standard", "mac-benchmark-standard-v6"],
    ["quick", "mac-benchmark-quick-v3"],
    ["full", "mac-benchmark-full-v3"],
  ] satisfies Array<[BenchmarkProfile, WorkloadVersion]>)(
    "accepts targeted cleanup for %s / %s",
    (profile, workloadVersion) => {
      expect(validateDeletion({
        installationId: "123e4567-e89b-42d3-a456-426614174001",
        profile,
        workloadVersion,
      })).toEqual({
        installationId: "123e4567-e89b-42d3-a456-426614174001",
        profile,
        workloadVersion,
      });
    },
  );

  it("rejects a profile/workload mismatch", () => {
    expect(() => validateDeletion({
      installationId: "123e4567-e89b-42d3-a456-426614174001",
      profile: "standard",
      workloadVersion: "mac-benchmark-quick-v3",
    })).toThrowError(
      expect.objectContaining<Partial<SubmissionValidationError>>({
        field: "workloadVersion",
      }),
    );
  });
});

function unitRatios(): BenchmarkMetricRatios {
  return uniformRatios(1);
}

function referenceCapacity() {
  return {
    physicalMemoryBytes: V6_REFERENCE_PHYSICAL_MEMORY_BYTES,
    systemDiskCapacityBytes: V6_REFERENCE_SYSTEM_DISK_CAPACITY_BYTES,
  };
}

function uniformRatios(value: number): BenchmarkMetricRatios {
  return {
    cpuSingle: value,
    cpuMulti: value,
    gpu: value,
    memory: value,
    diskRead: value,
    diskWrite: value,
  };
}

function validStandardRequest() {
  return validRequestFor(
    "standard",
    "mac-benchmark-standard-v6",
    "m5-pro-2026-07-v6",
    "1.8.2",
  );
}

function validStandardV4Request() {
  return validRequestFor(
    "standard",
    "mac-benchmark-standard-v4",
    "m5-pro-2026-07-v4",
    "1.8.2",
  );
}

function stabilityEvidence(
  coefficientOfVariation: number,
  sampleCount: number,
): BenchmarkStabilityEvidence {
  const entry = () => ({ coefficientOfVariation, sampleCount });
  return {
    cpuSingle: entry(),
    cpuMulti: entry(),
    gpu: entry(),
    memory: entry(),
    diskRead: entry(),
    diskWrite: entry(),
  };
}

function validRequestFor(
  profile: BenchmarkProfile,
  workloadVersion: FrozenWorkloadVersion,
  baselineVersion: string,
  appVersion: string,
) {
  const metrics: BenchmarkMetrics = { ...REFERENCE_METRICS[workloadVersion] };
  if (workloadVersion === "mac-benchmark-standard-v6") {
    metrics.stability = stabilityEvidence(0.01, V6_REQUIRED_SAMPLE_COUNT);
  }
  return {
    submissionId: "123e4567-e89b-42d3-a456-426614174000",
    installationId: "123e4567-e89b-42d3-a456-426614174001",
    displayName: "工作室 Mac",
    processorModel: "Apple M5 Pro",
    profile,
    workloadVersion: workloadVersion as WorkloadVersion,
    baselineVersion,
    architecture: "arm64",
    completedAt: "2026-07-17T05:30:00.000Z",
    appVersion,
    appBuild: "202607172016",
    conditions: {
      powerSource: "acPower",
      lowPowerModeEnabled: false,
      preflightThermalState: "nominal",
      postflightThermalState: "nominal",
    },
    metrics,
    proposedScore: 6_000,
  };
}
