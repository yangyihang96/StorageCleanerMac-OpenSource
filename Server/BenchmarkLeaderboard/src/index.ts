import {
  ACTIVE_BASELINE_VERSION,
  API_SCHEMA_VERSION,
  BASELINE_BY_WORKLOAD,
  DEFAULT_PAGE_SIZE,
  MAX_PAGE_SIZE,
  MAX_REQUEST_BYTES,
  type BenchmarkProfile,
  type Env,
  type LeaderboardRow,
} from "./contracts";
import {
  SubmissionValidationError,
  computeScore,
  validateDeletion,
  validateLeaderboardWorkload,
  validateSubmission,
  validateSubmissionWorkloadActivation,
} from "./scoring";
import { assertHMACSecret, hmacHex, sha256Hex } from "./crypto";
import { handleV2Request, isV2Path } from "./v2";

const JSON_HEADERS = {
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
  "X-Leaderboard-Schema": String(API_SCHEMA_VERSION),
  "Referrer-Policy": "no-referrer",
} as const;

interface CountRow {
  total: number;
}

interface RankedRow extends LeaderboardRow {
  rank: number;
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
};

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  try {
    const url = new URL(request.url);
    if (isV2Path(url.pathname)) return await handleV2Request(request, env, url);
    if (request.method === "OPTIONS") return optionsResponse();
    if (request.method === "GET" && url.pathname === "/v1/health") {
      return json({
        status: "ok",
        schemaVersion: API_SCHEMA_VERSION,
        baselineVersion: ACTIVE_BASELINE_VERSION,
      });
    }
    if (request.method === "GET" && url.pathname === "/v1/leaderboard") {
      return await getLeaderboard(url, env);
    }
    if (request.method === "POST" && url.pathname === "/v1/submissions") {
      return await submitScore(request, env);
    }
    if (request.method === "DELETE" && url.pathname === "/v1/submissions") {
      return await deleteScore(request, env);
    }
    if (
      url.pathname === "/v1/health" ||
      url.pathname === "/v1/leaderboard" ||
      url.pathname === "/v1/submissions"
    ) {
      return errorResponse(405, "method_not_allowed", "不支持此请求方法");
    }
    return errorResponse(404, "not_found", "未找到请求的接口");
  } catch (error) {
    if (error instanceof SubmissionValidationError) {
      const status = error.code === "incompatible_source_version"
        || error.code === "unsupported_workload_version"
        ? 422
        : error.code === "unsupported_media_type"
          ? 415
          : error.code === "payload_too_large"
            ? 413
            : 400;
      return errorResponse(status, error.code, "请求内容不符合排行榜要求", {
        field: error.field,
      });
    }
    return errorResponse(500, "internal_error", "排行榜服务暂时不可用");
  }
}

async function getLeaderboard(url: URL, env: Env): Promise<Response> {
  const profile = parseProfile(url.searchParams.get("profile"));
  const workloadVersion = validateLeaderboardWorkload(
    profile,
    url.searchParams.get("workloadVersion"),
  );
  const page = parseInteger(url.searchParams.get("page"), 1, 1, 10_000, "page");
  const pageSize = parseInteger(
    url.searchParams.get("pageSize"),
    DEFAULT_PAGE_SIZE,
    1,
    MAX_PAGE_SIZE,
    "pageSize",
  );
  const offset = (page - 1) * pageSize;

  const countRow = await env.DB.prepare(
    `SELECT COUNT(*) AS total
     FROM leaderboard_entries
     WHERE profile = ?1 AND workload_version = ?2
       AND physical_memory_bytes IS NOT NULL
       AND system_disk_capacity_bytes IS NOT NULL`,
  )
    .bind(profile, workloadVersion)
    .first<CountRow>();
  const total = Number(countRow?.total ?? 0);
  const rows = await env.DB.prepare(
    `SELECT id, display_name, processor_model, score, profile,
            workload_version, physical_memory_bytes,
            system_disk_capacity_bytes, completed_at, rank
     FROM (
       SELECT id, display_name, processor_model, score, profile,
              workload_version, physical_memory_bytes,
              system_disk_capacity_bytes, completed_at,
              ROW_NUMBER() OVER (
                ORDER BY score DESC, completed_at ASC, id ASC
              ) AS rank
       FROM leaderboard_entries
       WHERE profile = ?1 AND workload_version = ?2
         AND physical_memory_bytes IS NOT NULL
         AND system_disk_capacity_bytes IS NOT NULL
     )
     LIMIT ?3 OFFSET ?4`,
  )
    .bind(profile, workloadVersion, pageSize, offset)
    .all<RankedRow>();

  return json(
    {
      data: rows.results.map(publicEntry),
      pagination: {
        page,
        pageSize,
        total,
        totalPages: total === 0 ? 0 : Math.ceil(total / pageSize),
      },
      meta: {
        baselineVersion: BASELINE_BY_WORKLOAD[workloadVersion],
        profile,
        workloadVersion,
        generatedAt: new Date().toISOString(),
      },
    },
    200,
    { "Cache-Control": "public, max-age=30" },
  );
}

async function submitScore(request: Request, env: Env): Promise<Response> {
  const decoded = await readJSONBody(request);
  validateSubmissionWorkloadActivation(decoded);
  const submission = validateSubmission(decoded);
  assertHMACSecret(env.IDENTITY_HMAC_KEY);
  const installationHash = await hmacHex(
    env.IDENTITY_HMAC_KEY,
    `leaderboard-installation-v1:${submission.installationId}`,
  );
  if (env.SUBMISSION_RATE_LIMITER) {
    const rate = await env.SUBMISSION_RATE_LIMITER.limit({ key: installationHash });
    if (!rate.success) {
      return errorResponse(429, "rate_limited", "上传过于频繁，请稍后重试", undefined, {
        "Retry-After": "60",
      });
    }
  }

  const id = (await sha256Hex(
    `leaderboard-entry-v1:${installationHash}:${submission.profile}:${submission.workloadVersion}`,
  )).slice(0, 32);
  const existing = await env.DB.prepare(
    `SELECT id FROM leaderboard_entries
     WHERE installation_hash = ?1 AND profile = ?2 AND workload_version = ?3`,
  )
    .bind(installationHash, submission.profile, submission.workloadVersion)
    .first<{ id: string }>();
  const score = computeScore(submission.workloadVersion, submission.metrics);
  const submittedAt = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO leaderboard_entries (
       id, installation_hash, last_submission_id, display_name,
       processor_model, profile, workload_version, baseline_version,
       architecture, score, cpu_single, cpu_multi, gpu, memory,
       disk_read, disk_write, physical_memory_bytes,
       system_disk_capacity_bytes, completed_at, submitted_at,
       app_version, app_build
     ) VALUES (
       ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
       ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20,
       ?21, ?22
     )
     ON CONFLICT (installation_hash, profile, workload_version)
     DO UPDATE SET
       last_submission_id = excluded.last_submission_id,
       display_name = excluded.display_name,
       processor_model = excluded.processor_model,
       baseline_version = excluded.baseline_version,
       architecture = excluded.architecture,
       score = excluded.score,
       cpu_single = excluded.cpu_single,
       cpu_multi = excluded.cpu_multi,
       gpu = excluded.gpu,
       memory = excluded.memory,
       disk_read = excluded.disk_read,
       disk_write = excluded.disk_write,
       physical_memory_bytes = excluded.physical_memory_bytes,
       system_disk_capacity_bytes = excluded.system_disk_capacity_bytes,
       completed_at = excluded.completed_at,
       submitted_at = excluded.submitted_at,
       app_version = excluded.app_version,
       app_build = excluded.app_build
     WHERE excluded.score > leaderboard_entries.score`,
  )
    .bind(
      id,
      installationHash,
      submission.submissionId,
      submission.displayName,
      submission.processorModel,
      submission.profile,
      submission.workloadVersion,
      submission.baselineVersion,
      "arm64",
      score,
      submission.metrics.cpuSingle,
      submission.metrics.cpuMulti,
      submission.metrics.gpu,
      submission.metrics.memory,
      submission.metrics.diskRead,
      submission.metrics.diskWrite,
      submission.metrics.physicalMemoryBytes ?? null,
      submission.metrics.systemDiskCapacityBytes ?? null,
      submission.completedAt,
      submittedAt,
      submission.appVersion,
      submission.appBuild,
    )
    .run();

  const row = await env.DB.prepare(
    `SELECT id, display_name, processor_model, score, profile,
            workload_version, physical_memory_bytes,
            system_disk_capacity_bytes, completed_at
     FROM leaderboard_entries WHERE id = ?1`,
  )
    .bind(id)
    .first<LeaderboardRow>();
  if (!row) throw new Error("Inserted leaderboard row not found");

  const rankRow = await env.DB.prepare(
    `SELECT 1 + COUNT(*) AS rank
     FROM leaderboard_entries
     WHERE profile = ?1 AND workload_version = ?2
       AND physical_memory_bytes IS NOT NULL
       AND system_disk_capacity_bytes IS NOT NULL
       AND (
       score > ?3 OR
       (score = ?3 AND completed_at < ?4) OR
       (score = ?3 AND completed_at = ?4 AND id < ?5)
     )`,
  )
    .bind(row.profile, row.workload_version, row.score, row.completed_at, row.id)
    .first<{ rank: number }>();
  const ranked: RankedRow = { ...row, rank: Number(rankRow?.rank ?? 1) };

  return json(
    {
      data: publicEntry(ranked),
      disposition: existing ? "updated" : "created",
      meta: {
        baselineVersion: submission.baselineVersion,
        submittedAt,
      },
    },
    existing ? 200 : 201,
    { "Cache-Control": "no-store" },
  );
}

async function deleteScore(request: Request, env: Env): Promise<Response> {
  const deletion = validateDeletion(await readJSONBody(request));
  assertHMACSecret(env.IDENTITY_HMAC_KEY);
  const installationHash = await hmacHex(
    env.IDENTITY_HMAC_KEY,
    `leaderboard-installation-v1:${deletion.installationId}`,
  );
  if (env.SUBMISSION_RATE_LIMITER) {
    const rate = await env.SUBMISSION_RATE_LIMITER.limit({ key: installationHash });
    if (!rate.success) {
      return errorResponse(429, "rate_limited", "操作过于频繁，请稍后重试", undefined, {
        "Retry-After": "60",
      });
    }
  }
  const result = await env.DB.prepare(
    `DELETE FROM leaderboard_entries
     WHERE installation_hash = ?1 AND profile = ?2 AND workload_version = ?3`,
  )
    .bind(installationHash, deletion.profile, deletion.workloadVersion)
    .run();
  return json(
    {
      data: { deleted: (result.meta.changes ?? 0) > 0 },
      meta: {
        profile: deletion.profile,
        workloadVersion: deletion.workloadVersion,
        deletedAt: new Date().toISOString(),
      },
    },
    200,
    { "Cache-Control": "no-store" },
  );
}

async function readJSONBody(request: Request): Promise<unknown> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new SubmissionValidationError("body", "unsupported_media_type");
  }
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new SubmissionValidationError("body", "payload_too_large");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_REQUEST_BYTES) {
    throw new SubmissionValidationError("body", "payload_too_large");
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new SubmissionValidationError("body");
  }
}

function publicEntry(row: RankedRow) {
  return {
    id: row.id,
    rank: Number(row.rank),
    displayName: row.display_name,
    processorModel: row.processor_model,
    score: Number(row.score),
    profile: row.profile,
    workloadVersion: row.workload_version,
    physicalMemoryBytes: Number(row.physical_memory_bytes),
    systemDiskCapacityBytes: Number(row.system_disk_capacity_bytes),
    completedAt: row.completed_at,
  };
}

function parseProfile(value: string | null): BenchmarkProfile {
  if (value !== "standard" && value !== "quick" && value !== "full") {
    throw new SubmissionValidationError("profile");
  }
  return value;
}

function parseInteger(
  value: string | null,
  fallback: number,
  minimum: number,
  maximum: number,
  field: string,
): number {
  if (value === null) return fallback;
  if (!/^\d+$/.test(value)) throw new SubmissionValidationError(field);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new SubmissionValidationError(field);
  }
  return number;
}

function json(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...JSON_HEADERS,
      ...corsHeaders(),
      ...extraHeaders,
    },
  });
}

function errorResponse(
  status: number,
  code: string,
  message: string,
  details?: Record<string, unknown>,
  headers: Record<string, string> = {},
): Response {
  return json(
    {
      error: {
        code,
        message,
        ...(details ? { details } : {}),
      },
    },
    status,
    { "Cache-Control": "no-store", ...headers },
  );
}

function optionsResponse(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      ...corsHeaders(),
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
      "Access-Control-Max-Age": "86400",
      "X-Leaderboard-Schema": String(API_SCHEMA_VERSION),
    },
  });
}

function corsHeaders(): Record<string, string> {
  return { "Access-Control-Allow-Origin": "*" };
}
