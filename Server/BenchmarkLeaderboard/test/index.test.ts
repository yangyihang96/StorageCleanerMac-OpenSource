import { describe, expect, it } from "vitest";
import {
  REFERENCE_METRICS,
  type BenchmarkProfile,
  type Env,
  type WorkloadVersion,
} from "../src/contracts";
import { handleRequest } from "../src/index";

const unusedEnv = {} as Env;

describe("leaderboard routes", () => {
  it("reports the active schema and last genuinely frozen baseline", async () => {
    const response = await handleRequest(
      new Request("https://leaderboard.example/v1/health"),
      unusedEnv,
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("X-Leaderboard-Schema")).toBe("1");
    await expect(response.json()).resolves.toEqual({
      status: "ok",
      schemaVersion: 1,
      baselineVersion: "m5-pro-2026-07-v6",
    });
  });

  it("exposes only Standard v6 rows with the complete public hardware contract", async () => {
    const fixture = leaderboardEnv([
      fixtureRow("standard-v6", "standard", "mac-benchmark-standard-v6", 6_000),
      fixtureRow("standard-v4", "standard", "mac-benchmark-standard-v4", 6_000),
      fixtureRow("standard-v5", "standard", "mac-benchmark-standard-v5", 99_000),
      fixtureRow("quick-v3", "quick", "mac-benchmark-quick-v3", 5_800),
      fixtureRow("full-v3", "full", "mac-benchmark-full-v3", 6_100),
    ]);

    const standard = await handleRequest(
      new Request(
        "https://leaderboard.example/v1/leaderboard?profile=standard&workloadVersion=mac-benchmark-standard-v6",
      ),
      fixture.env,
    );
    expect(standard.status).toBe(200);
    await expect(standard.json()).resolves.toMatchObject({
      data: [{
        id: "standard-v6",
        processorModel: "Apple M5 Pro",
        score: 6_000,
        workloadVersion: "mac-benchmark-standard-v6",
        physicalMemoryBytes: 51_539_607_552,
        systemDiskCapacityBytes: 994_610_155_520,
        completedAt: "2026-07-17T05:30:00.000Z",
      }],
      pagination: { total: 1 },
      meta: {
        profile: "standard",
        workloadVersion: "mac-benchmark-standard-v6",
        baselineVersion: "m5-pro-2026-07-v6",
      },
    });
    expect(fixture.bindings.slice(0, 2).every((values) =>
      values[0] === "standard" && values[1] === "mac-benchmark-standard-v6"
    )).toBe(true);
  });

  it.each([
    ["standard", "mac-benchmark-standard-v4"],
    ["standard", "mac-benchmark-standard-v5"],
    ["quick", "mac-benchmark-quick-v3"],
    ["full", "mac-benchmark-full-v3"],
  ] satisfies Array<[BenchmarkProfile, WorkloadVersion]>)(
    "rejects non-public %s / %s leaderboard queries before database access",
    async (profile, workloadVersion) => {
      const response = await handleRequest(
        new Request(
          `https://leaderboard.example/v1/leaderboard?profile=${profile}&workloadVersion=${workloadVersion}`,
        ),
        unusedEnv,
      );
      expect(response.status).toBe(422);
      await expect(response.json()).resolves.toMatchObject({
        error: {
          code: "unsupported_workload_version",
          details: { field: "workloadVersion" },
        },
      });
    },
  );

  it.each([
    ["standard", "mac-benchmark-standard-v4", "m5-pro-2026-07-v4"],
    ["quick", "mac-benchmark-quick-v3", "m5-pro-2026-07-v3"],
    ["full", "mac-benchmark-full-v3", "m5-pro-2026-07-v3"],
  ] satisfies Array<[BenchmarkProfile, WorkloadVersion, string]>)(
    "rejects non-public %s / %s submissions before database access",
    async (profile, workloadVersion, baselineVersion) => {
      const body = {
        ...validStandardV6Submission(),
        profile,
        workloadVersion,
        baselineVersion,
      };
      const response = await handleRequest(
        jsonRequest("https://leaderboard.example/v1/submissions", "POST", body),
        unusedEnv,
      );
      expect(response.status).toBe(422);
      await expect(response.json()).resolves.toMatchObject({
        error: {
          code: "unsupported_workload_version",
          details: { field: "workloadVersion" },
        },
      });
    },
  );

  it("rejects invalid profile/workload comparison keys before database access", async () => {
    const response = await handleRequest(
      new Request(
        "https://leaderboard.example/v1/leaderboard?profile=standard&workloadVersion=mac-benchmark-full-v3",
      ),
      unusedEnv,
    );
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "invalid_submission", details: { field: "workloadVersion" } },
    });
  });

  it("rejects an incomplete v6 submission without touching the database", async () => {
    const body = validStandardV6Submission();
    delete (body.metrics as {
      stability?: ReturnType<typeof v6StabilityEvidence>;
    }).stability;
    const response = await handleRequest(
      jsonRequest("https://leaderboard.example/v1/submissions", "POST", body),
      unusedEnv,
    );
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: "invalid_submission",
        details: { field: "metrics.stability" },
      },
    });
  });

  it("preserves required v6 capacity metadata in the POST SQL binding", async () => {
    const fixture = submissionEnv();
    const body = validStandardV6Submission();

    const response = await handleRequest(
      jsonRequest("https://leaderboard.example/v1/submissions", "POST", body),
      fixture.env,
    );
    expect(response.status).toBe(201);
    const insert = fixture.statements.find(({ sql }) =>
      sql.includes("INSERT INTO leaderboard_entries")
    );
    expect(insert).toBeDefined();
    expect(insert?.sql).toContain(
      "WHERE excluded.score > leaderboard_entries.score",
    );
    expect(insert?.values[16]).toBe(51_539_607_552);
    expect(insert?.values[17]).toBe(994_610_155_520);
    await expect(response.json()).resolves.toMatchObject({
      data: {
        score: 6_000,
        profile: "standard",
        workloadVersion: "mac-benchmark-standard-v6",
        physicalMemoryBytes: 51_539_607_552,
        systemDiskCapacityBytes: 994_610_155_520,
      },
      disposition: "created",
      meta: { baselineVersion: "m5-pro-2026-07-v6" },
    });
  });

  it.each([
    "mac-benchmark-standard-v5",
    "mac-benchmark-standard-v6",
  ] satisfies WorkloadVersion[])(
    "allows targeted deletion of possible stale %s rows",
    async (workloadVersion) => {
      const fixture = deletionEnv();
      const response = await handleRequest(
        jsonRequest("https://leaderboard.example/v1/submissions", "DELETE", {
          installationId: "123e4567-e89b-42d3-a456-426614174001",
          profile: "standard",
          workloadVersion,
        }),
        fixture.env,
      );
      expect(response.status).toBe(200);
      await expect(response.json()).resolves.toMatchObject({
        data: { deleted: true },
        meta: { profile: "standard", workloadVersion },
      });
      expect(fixture.bindings).toHaveLength(1);
      expect(fixture.bindings[0]?.[1]).toBe("standard");
      expect(fixture.bindings[0]?.[2]).toBe(workloadVersion);
    },
  );

  it("uses stable error contracts for unknown routes and methods", async () => {
    const missing = await handleRequest(
      new Request("https://leaderboard.example/v1/missing"),
      unusedEnv,
    );
    expect(missing.status).toBe(404);
    await expect(missing.json()).resolves.toMatchObject({
      error: { code: "not_found" },
    });

    const method = await handleRequest(
      new Request("https://leaderboard.example/v1/health", { method: "POST" }),
      unusedEnv,
    );
    expect(method.status).toBe(405);
  });
});

interface FixtureRow {
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

function fixtureRow(
  id: string,
  profile: BenchmarkProfile,
  workloadVersion: WorkloadVersion,
  score: number,
): FixtureRow {
  return {
    id,
    display_name: id,
    processor_model: "Apple M5 Pro",
    score,
    profile,
    workload_version: workloadVersion,
    physical_memory_bytes: 51_539_607_552,
    system_disk_capacity_bytes: 994_610_155_520,
    completed_at: "2026-07-17T05:30:00.000Z",
  };
}

function leaderboardEnv(rows: FixtureRow[]) {
  const bindings: unknown[][] = [];
  const db = {
    prepare(_sql: string) {
      return {
        bind(...values: unknown[]) {
          bindings.push(values);
          const profile = values[0];
          const workloadVersion = values[1];
          const filtered = rows
            .filter((row) =>
              row.profile === profile && row.workload_version === workloadVersion
            )
            .sort((lhs, rhs) => rhs.score - lhs.score);
          return {
            async first() {
              return { total: filtered.length };
            },
            async all() {
              const pageSize = Number(values[2] ?? filtered.length);
              const offset = Number(values[3] ?? 0);
              return {
                results: filtered.slice(offset, offset + pageSize).map((row, index) => ({
                  ...row,
                  rank: offset + index + 1,
                })),
              };
            },
          };
        },
      };
    },
  };
  return {
    bindings,
    env: {
      DB: db,
      IDENTITY_HMAC_KEY: "not-used-by-get".padEnd(32, "x"),
    } as unknown as Env,
  };
}

function deletionEnv() {
  const bindings: unknown[][] = [];
  const db = {
    prepare(_sql: string) {
      return {
        bind(...values: unknown[]) {
          bindings.push(values);
          return {
            async run() {
              return { meta: { changes: 1 } };
            },
          };
        },
      };
    },
  };
  return {
    bindings,
    env: {
      DB: db,
      IDENTITY_HMAC_KEY: "leaderboard-test-secret-key-32-bytes-minimum",
    } as unknown as Env,
  };
}

function submissionEnv() {
  const statements: Array<{ sql: string; values: unknown[] }> = [];
  let insertValues: unknown[] | undefined;
  const db = {
    prepare(sql: string) {
      return {
        bind(...values: unknown[]) {
          statements.push({ sql, values });
          return {
            async first() {
              if (
                sql.includes("SELECT id FROM leaderboard_entries")
                && sql.includes("installation_hash")
              ) {
                return null;
              }
              if (sql.includes("FROM leaderboard_entries WHERE id = ?1")) {
                if (!insertValues) throw new Error("insert was not captured");
                return {
                  id: String(insertValues[0]),
                  display_name: String(insertValues[3]),
                  processor_model: String(insertValues[4]),
                  score: Number(insertValues[9]),
                  profile: insertValues[5],
                  workload_version: insertValues[6],
                  physical_memory_bytes: Number(insertValues[16]),
                  system_disk_capacity_bytes: Number(insertValues[17]),
                  completed_at: String(insertValues[18]),
                };
              }
              if (sql.includes("SELECT 1 + COUNT(*) AS rank")) {
                return { rank: 1 };
              }
              throw new Error(`unexpected first() statement: ${sql}`);
            },
            async run() {
              if (!sql.includes("INSERT INTO leaderboard_entries")) {
                throw new Error(`unexpected run() statement: ${sql}`);
              }
              insertValues = values;
              return { meta: { changes: 1 } };
            },
          };
        },
      };
    },
  };
  return {
    statements,
    env: {
      DB: db,
      IDENTITY_HMAC_KEY: "leaderboard-test-secret-key-32-bytes-minimum",
    } as unknown as Env,
  };
}

function jsonRequest(url: string, method: string, body: unknown): Request {
  return new Request(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function validStandardV6Submission() {
  return {
    submissionId: "123e4567-e89b-42d3-a456-426614174000",
    installationId: "123e4567-e89b-42d3-a456-426614174001",
    displayName: "工作室 Mac",
    processorModel: "Apple M5 Pro",
    profile: "standard",
    workloadVersion: "mac-benchmark-standard-v6" as WorkloadVersion,
    baselineVersion: "m5-pro-2026-07-v6",
    architecture: "arm64",
    completedAt: new Date().toISOString(),
    appVersion: "1.8.2",
    appBuild: "202607172016",
    conditions: {
      powerSource: "acPower",
      lowPowerModeEnabled: false,
      preflightThermalState: "nominal",
      postflightThermalState: "nominal",
    },
    metrics: {
      ...REFERENCE_METRICS["mac-benchmark-standard-v6"],
      stability: v6StabilityEvidence(),
    },
    proposedScore: 6_000,
  };
}

function v6StabilityEvidence() {
  const evidence = () => ({
    coefficientOfVariation: 0.01,
    sampleCount: 3,
  });
  return {
    cpuSingle: evidence(),
    cpuMulti: evidence(),
    gpu: evidence(),
    memory: evidence(),
    diskRead: evidence(),
    diskWrite: evidence(),
  };
}
