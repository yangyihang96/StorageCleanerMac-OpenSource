import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { handleRequest } from "../src/index";
import { handleV2Request } from "../src/v2";
import {
  V2_CORE_METRICS,
  V2_MAX_REQUEST_BYTES,
  V2_PLAN_VERSION,
  V2_REFERENCE_SET_VERSION,
  V2_SCORING_VERSION,
  V2_WORKLOAD_VERSION,
  type V2Env,
  type V2Metrics,
} from "../src/v2-contracts";
import { computeV2CoreScore } from "../src/v2-scoring";

const SECRET = "leaderboard-v2-test-secret-key-at-least-32-bytes";

describe("V7 v2 routes", () => {
  it("keeps v1 unchanged while exposing the complete v2 health contract", async () => {
    const v1 = await handleRequest(
      new Request("https://leaderboard.example/v1/health"),
      {} as V2Env,
    );
    expect(v1.status).toBe(200);
    expect(v1.headers.get("X-Leaderboard-Schema")).toBe("1");
    await expect(v1.json()).resolves.toMatchObject({
      schemaVersion: 1,
      baselineVersion: "m5-pro-2026-07-v6",
    });

    const v2 = await handleRequest(
      new Request("https://leaderboard.example/v2/health"),
      {} as V2Env,
    );
    expect(v2.status).toBe(200);
    expect(v2.headers.get("X-Leaderboard-Schema")).toBe("2");
    await expect(v2.json()).resolves.toEqual({
      status: "ok",
      schemaVersion: 2,
      ...versions(),
    });

    const options = await handleRequest(new Request(
      "https://leaderboard.example/v2/submissions",
      { method: "OPTIONS" },
    ), {} as V2Env);
    expect(options.status).toBe(204);
    expect(options.headers.get("X-Leaderboard-Schema")).toBe("2");
  });

  it("paginates ranked rows and exposes only the public whitelist", async () => {
    const fixture = makeFixture();
    const first = validSubmission(1, 101, 1);
    const second = validSubmission(2, 102, 1.2);
    expect((await post(fixture.env, first)).status).toBe(201);
    expect((await post(fixture.env, second)).status).toBe(201);

    const response = await handleRequest(
      new Request(
        `https://leaderboard.example/v2/leaderboard?workloadVersion=${V2_WORKLOAD_VERSION}&page=1&pageSize=1`,
      ),
      fixture.env,
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("X-Leaderboard-Schema")).toBe("2");
    const body = await response.json() as {
      data: Array<Record<string, unknown>>;
      pagination: Record<string, number>;
      meta: Record<string, unknown>;
    };
    expect(body.pagination).toEqual({
      page: 1,
      pageSize: 1,
      total: 2,
      totalPages: 2,
    });
    expect(body.data).toHaveLength(1);
    expect(Object.keys(body.data[0] ?? {}).sort()).toEqual([
      "completedOn",
      "computerModel",
      "confidence",
      "displayName",
      "id",
      "memoryGB",
      "processorModel",
      "rank",
      "score",
      "workloadVersion",
    ]);
    expect(body.data[0]).toMatchObject({
      rank: 1,
      displayName: second.displayName,
      memoryGB: 48,
      workloadVersion: V2_WORKLOAD_VERSION,
    });
    expect(body.data[0]?.completedOn).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(Object.keys(body.meta).sort()).toEqual([
      "generatedAt",
      "planVersion",
      "referenceSetVersion",
      "scoringVersion",
      "workloadVersion",
    ]);
  });

  it("returns an exact stored receipt for an idempotent replay", async () => {
    const fixture = makeFixture();
    const body = validSubmission(10, 110, 1);
    const first = await post(fixture.env, body);
    const firstText = await first.text();
    const replay = await post(fixture.env, body);
    expect(first.status).toBe(201);
    expect(replay.status).toBe(201);
    expect(await replay.text()).toBe(firstText);
    expect(fixture.db.entries.size).toBe(1);
    expect(fixture.db.submissions.size).toBe(1);
  });

  it("replays the exact retained receipt after 31 days and expires it after 90", async () => {
    const fixture = makeFixture();
    const submittedAt = new Date("2026-08-05T02:00:00.000Z");
    const body = validSubmission(11, 111, 1);
    body.completedAt = submittedAt.toISOString();
    const first = await postAt(fixture.env, body, submittedAt);
    const firstText = await first.text();

    const replay = await postAt(
      fixture.env,
      body,
      new Date("2026-09-05T02:00:00.000Z"),
    );
    expect(replay.status).toBe(201);
    expect(await replay.text()).toBe(firstText);

    const expired = await postAt(
      fixture.env,
      body,
      new Date("2026-11-05T02:00:00.000Z"),
    );
    expect(expired.status).toBe(400);
    expect(fixture.db.submissions.size).toBe(0);
    expect(fixture.db.entries.size).toBe(1);
  });

  it("rejects submissionId reuse with a different payload", async () => {
    const fixture = makeFixture();
    const body = validSubmission(20, 120, 1);
    expect((await post(fixture.env, body)).status).toBe(201);
    const conflict = structuredClone(body);
    conflict.displayName = "匿名冲突";
    const response = await post(fixture.env, conflict);
    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "submission_id_conflict" },
    });
    expect(fixture.db.entries.size).toBe(1);
  });

  it("keeps the highest installation/workload score and returns unchanged", async () => {
    const fixture = makeFixture();
    const high = validSubmission(30, 130, 1);
    expect((await post(fixture.env, high)).status).toBe(201);
    const low = validSubmission(31, 130, 0.5);
    low.displayName = "不应覆盖";
    const response = await post(fixture.env, low);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      data: { displayName: high.displayName, score: 6_000 },
      disposition: "unchanged",
    });
    expect(fixture.db.entries.size).toBe(1);
    expect(fixture.db.submissions.size).toBe(2);
  });

  it("updates the same installation only when the new score is higher", async () => {
    const fixture = makeFixture();
    const first = validSubmission(32, 132, 1);
    expect((await post(fixture.env, first)).status).toBe(201);
    const higher = validSubmission(33, 132, 1.1);
    higher.displayName = "新的匿名名";
    const response = await post(fixture.env, higher);
    expect(response.status).toBe(200);
    const receipt = await response.json() as {
      data: { displayName: string; score: number };
      disposition: string;
    };
    expect(receipt.data.displayName).toBe(higher.displayName);
    expect(receipt.data.score).toBeCloseTo(6_600, 8);
    expect(receipt.disposition).toBe("updated");
    expect(fixture.db.entries.size).toBe(1);
  });

  it("rejects a recomputable 200x all-metric leaderboard amplification", async () => {
    const fixture = makeFixture();
    const attack = validSubmission(34, 134, 1);
    attack.metrics = ratioMetrics(200);
    attack.proposedScore = 1_200_000;

    const response = await post(fixture.env, attack);

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: "metric_out_of_range",
        details: { field: "metrics.cpu.single.mixed" },
      },
    });
    expect(fixture.db.entries.size).toBe(0);
    expect(fixture.db.submissions.size).toBe(0);
  });

  it("fails closed when either rate-limit binding or Cloudflare IP is absent", async () => {
    const body = validSubmission(40, 140, 1);
    const noLimiterDB = new MemoryV2Database();
    const noLimiter = await post({
      DB: noLimiterDB as unknown as D1Database,
      IDENTITY_HMAC_KEY: SECRET,
    }, body);
    expect(noLimiter.status).toBe(503);
    expect(noLimiterDB.submissions.size).toBe(0);

    const fixture = makeFixture();
    const noIP = await post(fixture.env, body, null);
    expect(noIP.status).toBe(503);
    expect(fixture.db.submissions.size).toBe(0);
  });

  it("rate limits by IP before streaming and cancels a body above 32 KiB", async () => {
    const fixture = makeFixture();
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.enqueue(new Uint8Array(V2_MAX_REQUEST_BYTES + 1));
      },
      cancel() {
        cancelled = true;
      },
    });
    const request = new Request(
      "https://leaderboard.example/v2/submissions",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.10",
        },
        body: stream,
        duplex: "half",
      } as RequestInit & { duplex: "half" },
    );

    const response = await handleRequest(request, fixture.env);

    expect(response.status).toBe(413);
    expect(cancelled).toBe(true);
    expect(fixture.limiter.keys.filter((key) => key.startsWith("v2:ip:")))
      .toHaveLength(1);
    expect(fixture.limiter.keys.filter((key) => key.startsWith("v2:installation:")))
      .toHaveLength(0);
  });

  it("blocks installation UUID rotation through the shared HMAC IP key", async () => {
    const fixture = makeFixture(1);
    expect((await post(fixture.env, validSubmission(50, 150, 1))).status).toBe(201);
    const rotated = await post(
      fixture.env,
      validSubmission(51, 151, 1),
    );
    expect(rotated.status).toBe(429);
    const ipKeys = fixture.limiter.keys.filter((key) => key.startsWith("v2:ip:"));
    expect(ipKeys).toHaveLength(2);
    expect(new Set(ipKeys).size).toBe(1);
    expect(fixture.db.entries.size).toBe(1);
  });

  it("idempotently deletes the owned entry and tombstones stale retries", async () => {
    const fixture = makeFixture();
    const body = validSubmission(60, 160, 1);
    expect((await post(fixture.env, body)).status).toBe(201);
    const deletion = await remove(fixture.env, body.installationId);
    expect(deletion.status).toBe(200);
    await expect(deletion.json()).resolves.toMatchObject({
      data: { deleted: true },
      meta: versions(),
    });
    expect(fixture.db.entries.size).toBe(0);
    expect(fixture.db.submissions.size).toBe(0);
    expect(fixture.db.deletions.size).toBe(1);
    expect((await remove(fixture.env, body.installationId)).status).toBe(200);

    const staleRetry = await post(fixture.env, body);
    expect(staleRetry.status).toBe(409);
    await expect(staleRetry.json()).resolves.toMatchObject({
      error: { code: "submission_superseded_by_removal" },
    });
    expect(fixture.db.entries.size).toBe(0);
    expect(fixture.db.submissions.size).toBe(0);
  });

  it("does not resurrect an entry when DELETE removes an active claim", async () => {
    const fixture = makeFixture();
    const body = validSubmission(61, 161, 1);
    let deletion: Response | undefined;
    fixture.db.afterNextReservation(async () => {
      deletion = await remove(fixture.env, body.installationId);
    });

    const submission = await post(fixture.env, body);

    expect(deletion?.status).toBe(200);
    expect(submission.status).toBe(409);
    expect(fixture.db.entries.size).toBe(0);
    expect(fixture.db.submissions.size).toBe(0);
  });

  it("blocks a deleted exact retry whose completion clock was four minutes fast", async () => {
    const fixture = makeFixture();
    const requestTime = new Date("2026-08-05T02:00:00.000Z");
    const deletionTime = new Date("2026-08-05T02:01:00.000Z");
    const body = validSubmission(65, 165, 1);
    body.completedAt = new Date("2026-08-05T02:04:00.000Z").toISOString();
    expect((await postAt(fixture.env, body, requestTime)).status).toBe(201);
    expect((await removeAt(
      fixture.env,
      body.installationId,
      deletionTime,
    )).status).toBe(200);

    const retry = await postAt(fixture.env, body, deletionTime);

    expect(retry.status).toBe(409);
    expect(fixture.db.entries.size).toBe(0);
    expect(fixture.db.submissions.size).toBe(0);
  });

  it("allows a genuinely new benchmark completed after the deletion tombstone", async () => {
    const fixture = makeFixture();
    const firstTime = new Date("2026-08-05T02:00:00.000Z");
    const deletionTime = new Date("2026-08-05T02:01:00.000Z");
    const freshTime = new Date("2026-08-05T02:07:00.000Z");
    const first = validSubmission(63, 163, 1);
    first.completedAt = firstTime.toISOString();
    expect((await postAt(fixture.env, first, firstTime)).status).toBe(201);
    expect((await removeAt(
      fixture.env,
      first.installationId,
      deletionTime,
    )).status).toBe(200);

    const fresh = validSubmission(64, 163, 1.1);
    fresh.completedAt = freshTime.toISOString();
    const response = await postAt(fixture.env, fresh, freshTime);

    expect(response.status).toBe(201);
    expect(fixture.db.entries.size).toBe(1);
    expect(fixture.db.submissions.size).toBe(1);
  });

  it("rolls back entry and ledger together when atomic finalization fails", async () => {
    const fixture = makeFixture();
    fixture.db.failNextCommitAfter(2);

    const response = await post(fixture.env, validSubmission(62, 162, 1));

    expect(response.status).toBe(500);
    expect(fixture.db.entries.size).toBe(0);
    expect(fixture.db.submissions.size).toBe(0);
    expect(fixture.db.batchSizes).toContain(4);
  });

  it("adds an RFC Allow header to v2 method errors", async () => {
    const response = await handleRequest(new Request(
      "https://leaderboard.example/v2/submissions",
      { method: "PUT" },
    ), {} as V2Env);
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST, DELETE, OPTIONS");
  });

  it("uses a strictly additive 0004 migration", () => {
    const sql = readFileSync(
      new URL("../migrations/0004_benchmark_v7_v2.sql", import.meta.url),
      "utf8",
    );
    expect(sql).toContain("CREATE TABLE benchmark_v7_entries");
    expect(sql).toContain("CREATE TABLE benchmark_v7_submissions");
    expect(sql).toContain("CREATE TABLE benchmark_v7_deletions");
    expect(sql).toContain("score > 0 AND score <= 1000000");
    expect(sql).not.toMatch(/DROP\s+TABLE\s+leaderboard_entries/i);
    expect(sql).not.toMatch(/ALTER\s+TABLE\s+leaderboard_entries/i);
  });
});

interface StoredEntry {
  id: string;
  installation_hash: string;
  last_submission_id: string;
  display_name: string;
  computer_model: string;
  processor_model: string;
  memory_gb: number;
  score: number;
  workload_version: string;
  completed_on: string;
  confidence: string;
}

interface StoredSubmission {
  submission_id: string;
  request_hash: string;
  claim_token: string;
  installation_hash: string;
  workload_version: string;
  entry_id: string | null;
  disposition: string | null;
  receipt_json: string | null;
  response_status: number | null;
  created_at: string;
}

class MemoryV2Database {
  readonly entries = new Map<string, StoredEntry>();
  readonly submissions = new Map<string, StoredSubmission>();
  readonly deletions = new Map<string, string>();
  readonly batchSizes: number[] = [];
  private reservationHook: (() => Promise<void>) | undefined;
  private commitFailureAfter: number | undefined;

  afterNextReservation(hook: () => Promise<void>): void {
    this.reservationHook = hook;
  }

  failNextCommitAfter(statementCount: number): void {
    this.commitFailureAfter = statementCount;
  }

  prepare(sql: string): MemoryV2Statement {
    return new MemoryV2Statement(this, sql);
  }

  async batch(statements: MemoryV2Statement[]) {
    this.batchSizes.push(statements.length);
    const entries = cloneMap(this.entries);
    const submissions = cloneMap(this.submissions);
    const deletions = new Map(this.deletions);
    const results = [];
    try {
      for (const [index, statement] of statements.entries()) {
        results.push(await statement.executeForBatch());
        if (
          statements.length === 4
          && this.commitFailureAfter === index + 1
        ) {
          this.commitFailureAfter = undefined;
          throw new Error("Injected atomic commit failure");
        }
      }
      return results;
    } catch (error) {
      restoreMap(this.entries, entries);
      restoreMap(this.submissions, submissions);
      restoreMap(this.deletions, deletions);
      throw error;
    }
  }

  first(sql: string, values: unknown[]): unknown {
    if (sql.includes("SELECT COUNT(*) AS total") && sql.includes("benchmark_v7_entries")) {
      const workload = String(values[0]);
      return {
        total: [...this.entries.values()].filter(
          (entry) => entry.workload_version === workload,
        ).length,
      };
    }
    if (sql.includes("SELECT score FROM benchmark_v7_entries")) {
      const entry = this.entries.get(ownerKey(values[0], values[1]));
      return entry ? { score: entry.score } : null;
    }
    if (sql.includes("FROM benchmark_v7_entries WHERE id = ?1")) {
      return [...this.entries.values()].find(
        (entry) => entry.id === String(values[0]),
      ) ?? null;
    }
    if (sql.includes("SELECT 1 + COUNT(*) AS rank")) {
      const workload = String(values[0]);
      const score = Number(values[1]);
      const completedOn = String(values[2]);
      const id = String(values[3]);
      const ahead = [...this.entries.values()].filter((entry) =>
        entry.workload_version === workload && (
          entry.score > score
          || (entry.score === score && entry.completed_on < completedOn)
          || (entry.score === score
            && entry.completed_on === completedOn
            && entry.id < id)
        )
      ).length;
      return { rank: ahead + 1 };
    }
    if (sql.includes("FROM benchmark_v7_submissions WHERE submission_id = ?1")) {
      const row = this.submissions.get(String(values[0]));
      return row ? {
        request_hash: row.request_hash,
        receipt_json: row.receipt_json,
        response_status: row.response_status,
      } : null;
    }
    throw new Error(`Unexpected first SQL: ${normalizeSQL(sql)}`);
  }

  all(sql: string, values: unknown[]) {
    if (!sql.includes("ROW_NUMBER() OVER") || !sql.includes("benchmark_v7_entries")) {
      throw new Error(`Unexpected all SQL: ${normalizeSQL(sql)}`);
    }
    const workload = String(values[0]);
    const pageSize = Number(values[1]);
    const offset = Number(values[2]);
    const ranked = [...this.entries.values()]
      .filter((entry) => entry.workload_version === workload)
      .sort(compareEntries)
      .map((entry, index) => ({ ...entry, rank: index + 1 }));
    return { results: ranked.slice(offset, offset + pageSize), success: true };
  }

  async run(sql: string, values: unknown[]) {
    if (sql.includes("INSERT INTO benchmark_v7_submissions")) {
      const id = String(values[0]);
      if (this.submissions.has(id)) return result(0);
      const deletion = this.deletions.get(ownerKey(values[3], values[4]));
      if (
        deletion
        && new Date(String(values[6])).getTime()
          <= new Date(deletion).getTime() + 5 * 60 * 1_000
      ) return result(0);
      this.submissions.set(id, {
        submission_id: id,
        request_hash: String(values[1]),
        claim_token: String(values[2]),
        installation_hash: String(values[3]),
        workload_version: String(values[4]),
        entry_id: null,
        disposition: null,
        receipt_json: null,
        response_status: null,
        created_at: String(values[5]),
      });
      const hook = this.reservationHook;
      this.reservationHook = undefined;
      if (hook) await hook();
      return result(1);
    }
    if (sql.includes("SET disposition = CASE")) {
      const row = this.submissions.get(String(values[3]));
      if (
        !row
        || row.request_hash !== String(values[4])
        || row.claim_token !== String(values[5])
        || row.receipt_json !== null
      ) return result(0);
      const entry = this.entries.get(ownerKey(values[1], values[2]));
      row.disposition = !entry
        ? "created"
        : Number(values[0]) > entry.score ? "updated" : "unchanged";
      return result(1);
    }
    if (sql.includes("INSERT INTO benchmark_v7_entries")) {
      const claim = this.submissions.get(String(values[20]));
      if (
        !claim
        || claim.request_hash !== String(values[21])
        || claim.claim_token !== String(values[22])
        || claim.receipt_json !== null
      ) return result(0);
      const key = ownerKey(values[1], values[9]);
      const prior = this.entries.get(key);
      const score = Number(values[12]);
      if (prior && score <= prior.score) return result(0);
      this.entries.set(key, {
        id: String(values[0]),
        installation_hash: String(values[1]),
        last_submission_id: String(values[2]),
        display_name: String(values[3]),
        computer_model: String(values[4]),
        processor_model: String(values[5]),
        memory_gb: Number(values[6]),
        score,
        workload_version: String(values[9]),
        completed_on: String(values[14]),
        confidence: String(values[18]),
      });
      return result(1);
    }
    if (sql.includes("UPDATE benchmark_v7_submissions AS submission")) {
      const row = this.submissions.get(String(values[7]));
      if (
        !row
        || row.request_hash !== String(values[8])
        || row.claim_token !== String(values[9])
        || row.receipt_json !== null
      ) return result(0);
      const entry = this.entries.get(ownerKey(values[0], values[1]));
      if (!entry || !row.disposition) return result(0);
      const rank = [...this.entries.values()]
        .filter((candidate) => candidate.workload_version === entry.workload_version)
        .sort(compareEntries)
        .findIndex((candidate) => candidate.id === entry.id) + 1;
      row.entry_id = entry.id;
      row.response_status = row.disposition === "created" ? 201 : 200;
      row.receipt_json = JSON.stringify({
        data: {
          id: entry.id,
          rank,
          displayName: entry.display_name,
          computerModel: entry.computer_model,
          processorModel: entry.processor_model,
          memoryGB: entry.memory_gb,
          score: entry.score,
          workloadVersion: entry.workload_version,
          completedOn: entry.completed_on,
          confidence: entry.confidence,
        },
        disposition: row.disposition,
        meta: {
          submittedAt: String(values[2]),
          planVersion: String(values[3]),
          workloadVersion: String(values[4]),
          scoringVersion: String(values[5]),
          referenceSetVersion: String(values[6]),
        },
      });
      return result(1);
    }
    if (
      sql.includes("DELETE FROM benchmark_v7_submissions")
      && sql.includes("created_at < ?1")
    ) {
      let changes = 0;
      for (const [id, row] of this.submissions) {
        if (row.created_at < String(values[0])) {
          this.submissions.delete(id);
          changes += 1;
        }
      }
      return result(changes);
    }
    if (
      sql.includes("DELETE FROM benchmark_v7_submissions")
      && sql.includes("submission_id = ?1")
    ) {
      const id = String(values[0]);
      const row = this.submissions.get(id);
      if (
        row
        && row.request_hash === String(values[1])
        && row.claim_token === String(values[2])
        && row.receipt_json === null
      ) {
        this.submissions.delete(id);
        return result(1);
      }
      return result(0);
    }
    if (sql.includes("INSERT INTO benchmark_v7_deletions")) {
      const key = ownerKey(values[0], values[1]);
      const prior = this.deletions.get(key);
      const deletedAt = String(values[2]);
      this.deletions.set(key, prior && prior > deletedAt ? prior : deletedAt);
      return result(prior ? 0 : 1);
    }
    if (sql.includes("DELETE FROM benchmark_v7_submissions")) {
      let changes = 0;
      for (const [id, row] of this.submissions) {
        if (
          row.installation_hash === String(values[0])
          && row.workload_version === String(values[1])
        ) {
          this.submissions.delete(id);
          changes += 1;
        }
      }
      return result(changes);
    }
    if (sql.includes("DELETE FROM benchmark_v7_entries")) {
      const key = ownerKey(values[0], values[1]);
      const deleted = this.entries.delete(key);
      return result(deleted ? 1 : 0);
    }
    throw new Error(`Unexpected run SQL: ${normalizeSQL(sql)}`);
  }
}

class MemoryV2Statement {
  private values: unknown[] = [];

  constructor(
    private readonly database: MemoryV2Database,
    private readonly sql: string,
  ) {}

  bind(...values: unknown[]): this {
    this.values = values;
    return this;
  }

  async first<T>(): Promise<T | null> {
    return this.database.first(this.sql, this.values) as T | null;
  }

  async all<T>() {
    return this.database.all(this.sql, this.values) as {
      results: T[];
      success: boolean;
    };
  }

  async run() {
    return this.database.run(this.sql, this.values);
  }

  async executeForBatch() {
    if (normalizeSQL(this.sql).startsWith("SELECT ")) {
      const row = this.database.first(this.sql, this.values);
      return { success: true, meta: { changes: 0 }, results: row ? [row] : [] };
    }
    return this.run();
  }
}

class CountingRateLimiter {
  readonly keys: string[] = [];
  private readonly counts = new Map<string, number>();

  constructor(private readonly maximum: number) {}

  async limit(options: { key: string }) {
    this.keys.push(options.key);
    const count = (this.counts.get(options.key) ?? 0) + 1;
    this.counts.set(options.key, count);
    return { success: count <= this.maximum };
  }
}

function makeFixture(maximumRate = 100) {
  const db = new MemoryV2Database();
  const limiter = new CountingRateLimiter(maximumRate);
  return {
    db,
    limiter,
    env: {
      DB: db as unknown as D1Database,
      IDENTITY_HMAC_KEY: SECRET,
      SUBMISSION_RATE_LIMITER: limiter as unknown as RateLimit,
    } satisfies V2Env,
  };
}

function validSubmission(
  submissionSeed: number,
  installationSeed: number,
  ratio: number,
) {
  const metrics = ratioMetrics(ratio);
  return {
    submissionId: uuid(submissionSeed),
    installationId: uuid(installationSeed),
    displayName: `匿名 Mac ${submissionSeed}`,
    computerModel: "Mac17,9",
    processorModel: "Apple M5 Pro",
    memoryGB: 48,
    architecture: "arm64",
    planVersion: V2_PLAN_VERSION,
    workloadVersion: V2_WORKLOAD_VERSION,
    scoringVersion: V2_SCORING_VERSION,
    referenceSetVersion: V2_REFERENCE_SET_VERSION,
    completedAt: new Date().toISOString(),
    appVersion: "1.9.9",
    appBuild: "202608051049",
    conditions: {
      powerSource: "acPower",
      lowPowerModeEnabled: false,
      thermalState: "nominal",
      confidence: "high",
      sustainedReachedTargetDuration: true,
    },
    metrics,
    proposedScore: computeV2CoreScore(metrics),
  };
}

function ratioMetrics(ratio: number): V2Metrics {
  return Object.fromEntries(V2_CORE_METRICS.map((metric) => [
    metric.id,
    metric.direction === "higherIsBetter"
      ? metric.reference * ratio
      : metric.reference / ratio,
  ])) as V2Metrics;
}

async function post(
  env: V2Env,
  body: unknown,
  ip: string | null = "203.0.113.10",
): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (ip !== null) headers["CF-Connecting-IP"] = ip;
  return await handleRequest(new Request(
    "https://leaderboard.example/v2/submissions",
    { method: "POST", headers, body: JSON.stringify(body) },
  ), env);
}

async function postAt(
  env: V2Env,
  body: unknown,
  now: Date,
): Promise<Response> {
  const request = new Request(
    "https://leaderboard.example/v2/submissions",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "CF-Connecting-IP": "203.0.113.10",
      },
      body: JSON.stringify(body),
    },
  );
  return await handleV2Request(request, env, new URL(request.url), now);
}

async function remove(env: V2Env, installationId: string): Promise<Response> {
  return await handleRequest(new Request(
    "https://leaderboard.example/v2/submissions",
    {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "CF-Connecting-IP": "203.0.113.10",
      },
      body: JSON.stringify({
        installationId,
        workloadVersion: V2_WORKLOAD_VERSION,
      }),
    },
  ), env);
}

async function removeAt(
  env: V2Env,
  installationId: string,
  now: Date,
): Promise<Response> {
  const request = new Request(
    "https://leaderboard.example/v2/submissions",
    {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "CF-Connecting-IP": "203.0.113.10",
      },
      body: JSON.stringify({
        installationId,
        workloadVersion: V2_WORKLOAD_VERSION,
      }),
    },
  );
  return await handleV2Request(request, env, new URL(request.url), now);
}

function versions() {
  return {
    planVersion: V2_PLAN_VERSION,
    workloadVersion: V2_WORKLOAD_VERSION,
    scoringVersion: V2_SCORING_VERSION,
    referenceSetVersion: V2_REFERENCE_SET_VERSION,
  };
}

function uuid(seed: number): string {
  return `123e4567-e89b-42d3-a456-${seed.toString(16).padStart(12, "0")}`;
}

function ownerKey(installationHash: unknown, workloadVersion: unknown): string {
  return `${String(installationHash)}|${String(workloadVersion)}`;
}

function compareEntries(lhs: StoredEntry, rhs: StoredEntry): number {
  return rhs.score - lhs.score
    || lhs.completed_on.localeCompare(rhs.completed_on)
    || lhs.id.localeCompare(rhs.id);
}

function normalizeSQL(sql: string): string {
  return sql.replace(/\s+/g, " ").trim();
}

function cloneMap<Key, Value>(source: Map<Key, Value>): Map<Key, Value> {
  return new Map(
    [...source].map(([key, value]) => [key, structuredClone(value)]),
  );
}

function restoreMap<Key, Value>(
  target: Map<Key, Value>,
  snapshot: Map<Key, Value>,
): void {
  target.clear();
  for (const [key, value] of snapshot) target.set(key, value);
}

function result(changes: number) {
  return { success: true, meta: { changes }, results: [] };
}
