import { assertHMACSecret, hmacHex, sha256Hex } from "./crypto";
import {
  V2_API_SCHEMA_VERSION,
  V2_DEFAULT_PAGE_SIZE,
  V2_MAX_PAGE_SIZE,
  V2_MAX_REQUEST_BYTES,
  V2_PLAN_VERSION,
  V2_REFERENCE_SET_VERSION,
  V2_SCORING_VERSION,
  V2_SUBMISSION_RECEIPT_RETENTION_DAYS,
  V2_WORKLOAD_VERSION,
  type V2Env,
  type V2PublicEntry,
  type V2RankedRow,
  type V2ValidatedSubmission,
  type V2VersionMetadata,
} from "./v2-contracts";
import {
  V2ValidationError,
  assertV2SubmissionFresh,
  canonicalV2Submission,
  validateV2Deletion,
  validateV2Submission,
} from "./v2-scoring";

const V2_JSON_HEADERS = {
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
  "X-Leaderboard-Schema": String(V2_API_SCHEMA_VERSION),
  "Referrer-Policy": "no-referrer",
} as const;

interface CountRow {
  total: number;
}

interface SubmissionLedgerRow {
  request_hash: string;
  receipt_json: string | null;
  response_status: number | null;
}

class V2APIError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: Record<string, unknown>,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export function isV2Path(pathname: string): boolean {
  return pathname === "/v2" || pathname.startsWith("/v2/");
}

export async function handleV2Request(
  request: Request,
  env: V2Env,
  url = new URL(request.url),
  now = new Date(),
): Promise<Response> {
  try {
    if (request.method === "OPTIONS") return v2OptionsResponse();
    if (request.method === "GET" && url.pathname === "/v2/health") {
      return v2JSON({
        status: "ok",
        schemaVersion: V2_API_SCHEMA_VERSION,
        ...v2VersionMetadata(),
      }, 200, { "Cache-Control": "no-store" });
    }
    if (request.method === "GET" && url.pathname === "/v2/leaderboard") {
      return await getV2Leaderboard(url, env);
    }
    if (request.method === "POST" && url.pathname === "/v2/submissions") {
      return await submitV2Score(request, env, now);
    }
    if (request.method === "DELETE" && url.pathname === "/v2/submissions") {
      return await deleteV2Score(request, env, now);
    }
    if (
      url.pathname === "/v2/health"
      || url.pathname === "/v2/leaderboard"
      || url.pathname === "/v2/submissions"
    ) {
      return v2Error(
        405,
        "method_not_allowed",
        "不支持此请求方法",
        undefined,
        { Allow: v2AllowedMethods(url.pathname) },
      );
    }
    return v2Error(404, "not_found", "未找到请求的接口");
  } catch (error) {
    if (error instanceof V2APIError) {
      return v2Error(
        error.status,
        error.code,
        error.message,
        error.details,
        error.headers,
      );
    }
    if (error instanceof V2ValidationError) {
      const status = error.code === "unsupported_media_type"
        ? 415
        : error.code === "payload_too_large"
          ? 413
          : error.code === "unsupported_version" || error.code === "score_mismatch"
            ? 422
            : 400;
      return v2Error(status, error.code, "请求内容不符合 V7 排行榜要求", {
        field: error.field,
      });
    }
    return v2Error(500, "internal_error", "V7 排行榜服务暂时不可用");
  }
}

async function getV2Leaderboard(url: URL, env: V2Env): Promise<Response> {
  if (url.searchParams.get("workloadVersion") !== V2_WORKLOAD_VERSION) {
    throw new V2ValidationError("workloadVersion", "unsupported_version");
  }
  const page = parseV2Integer(url.searchParams.get("page"), 1, 1, 10_000, "page");
  const pageSize = parseV2Integer(
    url.searchParams.get("pageSize"),
    V2_DEFAULT_PAGE_SIZE,
    1,
    V2_MAX_PAGE_SIZE,
    "pageSize",
  );
  const offset = (page - 1) * pageSize;
  const countRow = await env.DB.prepare(
    `SELECT COUNT(*) AS total
     FROM benchmark_v7_entries
     WHERE workload_version = ?1`,
  )
    .bind(V2_WORKLOAD_VERSION)
    .first<CountRow>();
  const total = Number(countRow?.total ?? 0);
  if (!Number.isSafeInteger(total) || total < 0) throw new Error("Invalid row count");

  const rows = await env.DB.prepare(
    `SELECT id, display_name, computer_model, processor_model, memory_gb,
            score, workload_version, completed_on, confidence, rank
     FROM (
       SELECT id, display_name, computer_model, processor_model, memory_gb,
              score, workload_version, completed_on, confidence,
              ROW_NUMBER() OVER (
                ORDER BY score DESC, completed_on ASC, id ASC
              ) AS rank
       FROM benchmark_v7_entries
       WHERE workload_version = ?1
     )
     LIMIT ?2 OFFSET ?3`,
  )
    .bind(V2_WORKLOAD_VERSION, pageSize, offset)
    .all<V2RankedRow>();

  return v2JSON({
    data: rows.results.map(v2PublicEntry),
    pagination: {
      page,
      pageSize,
      total,
      totalPages: total === 0 ? 0 : Math.ceil(total / pageSize),
    },
    meta: {
      generatedAt: new Date().toISOString(),
      ...v2VersionMetadata(),
    },
  }, 200, { "Cache-Control": "public, max-age=30" });
}

async function submitV2Score(
  request: Request,
  env: V2Env,
  now: Date,
): Promise<Response> {
  await enforceV2IPRateLimit(request, env);
  const submission = validateV2Submission(
    await readV2JSONBody(request),
    now,
    false,
  );
  const installationHash = await v2InstallationHash(env, submission.installationId);
  await enforceV2InstallationRateLimit(env, installationHash);
  const requestHash = await sha256Hex(
    canonicalV2Submission(submission, installationHash),
  );
  const retainedReplay = await retainedV2SubmissionReplay(
    env,
    submission.submissionId,
    requestHash,
    now,
  );
  if (retainedReplay) return retainedReplay;

  // The 30-day window governs new writes. A retained exact replay remains
  // valid for the explicitly bounded ledger lifetime below.
  assertV2SubmissionFresh(submission, now);
  const submittedAt = now.toISOString();
  const claimToken = crypto.randomUUID();
  const reservation = await env.DB.prepare(
    `INSERT INTO benchmark_v7_submissions (
       submission_id, request_hash, claim_token, installation_hash, workload_version,
       entry_id, disposition, receipt_json, response_status, created_at
     )
     SELECT ?1, ?2, ?3, ?4, ?5, NULL, NULL, NULL, NULL, ?6
     WHERE NOT EXISTS (
       SELECT 1 FROM benchmark_v7_deletions
       WHERE installation_hash = ?4 AND workload_version = ?5
         AND datetime(?7) <= datetime(deleted_at, '+5 minutes')
     )
     ON CONFLICT (submission_id) DO NOTHING`,
  )
    .bind(
      submission.submissionId,
      requestHash,
      claimToken,
      installationHash,
      submission.workloadVersion,
      submittedAt,
      submission.completedAt,
    )
    .run();

  if (Number(reservation.meta.changes ?? 0) === 0) {
    return await replayV2Submission(
      env,
      submission.submissionId,
      requestHash,
    );
  }

  try {
    return await commitV2Submission(
      env,
      submission,
      installationHash,
      requestHash,
      claimToken,
      submittedAt,
    );
  } catch (error) {
    try {
      await env.DB.prepare(
        `DELETE FROM benchmark_v7_submissions
         WHERE submission_id = ?1 AND request_hash = ?2
           AND claim_token = ?3
           AND receipt_json IS NULL`,
      )
        .bind(submission.submissionId, requestHash, claimToken)
        .run();
    } catch {
      // Best-effort release of an unfinished reservation. A completed receipt
      // is never removed, so a retry remains safely idempotent.
    }
    throw error;
  }
}

async function commitV2Submission(
  env: V2Env,
  submission: V2ValidatedSubmission,
  installationHash: string,
  requestHash: string,
  claimToken: string,
  submittedAt: string,
): Promise<Response> {
  const id = (await sha256Hex(
    `leaderboard-entry-v2:${installationHash}:${submission.workloadVersion}`,
  )).slice(0, 32);
  // D1 batch executes as one SQLite transaction. The claim predicate makes a
  // DELETE that removed the reservation win without leaving an orphan entry.
  const results = await env.DB.batch([
    env.DB.prepare(
      `UPDATE benchmark_v7_submissions
       SET disposition = CASE
         WHEN NOT EXISTS (
           SELECT 1 FROM benchmark_v7_entries
           WHERE installation_hash = ?2 AND workload_version = ?3
         ) THEN 'created'
         WHEN ?1 > (
           SELECT score FROM benchmark_v7_entries
           WHERE installation_hash = ?2 AND workload_version = ?3
         ) THEN 'updated'
         ELSE 'unchanged'
       END
       WHERE submission_id = ?4 AND request_hash = ?5
         AND claim_token = ?6 AND receipt_json IS NULL`,
    ).bind(
      submission.proposedScore,
      installationHash,
      submission.workloadVersion,
      submission.submissionId,
      requestHash,
      claimToken,
    ),
    env.DB.prepare(
      `INSERT INTO benchmark_v7_entries (
         id, installation_hash, last_submission_id, display_name,
         computer_model, processor_model, memory_gb, architecture,
         plan_version, workload_version, scoring_version,
         reference_set_version, score, completed_at, completed_on,
         submitted_at, app_version, app_build, confidence, metrics_json
       )
       SELECT
         ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
         ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20
       WHERE EXISTS (
         SELECT 1 FROM benchmark_v7_submissions
         WHERE submission_id = ?21 AND request_hash = ?22
           AND claim_token = ?23 AND receipt_json IS NULL
       )
       ON CONFLICT (installation_hash, workload_version)
       DO UPDATE SET
         last_submission_id = excluded.last_submission_id,
         display_name = excluded.display_name,
         computer_model = excluded.computer_model,
         processor_model = excluded.processor_model,
         memory_gb = excluded.memory_gb,
         architecture = excluded.architecture,
         plan_version = excluded.plan_version,
         scoring_version = excluded.scoring_version,
         reference_set_version = excluded.reference_set_version,
         score = excluded.score,
         completed_at = excluded.completed_at,
         completed_on = excluded.completed_on,
         submitted_at = excluded.submitted_at,
         app_version = excluded.app_version,
         app_build = excluded.app_build,
         confidence = excluded.confidence,
         metrics_json = excluded.metrics_json
       WHERE excluded.score > benchmark_v7_entries.score`,
    ).bind(
      id,
      installationHash,
      submission.submissionId,
      submission.displayName,
      submission.computerModel,
      submission.processorModel,
      submission.memoryGB,
      submission.architecture,
      submission.planVersion,
      submission.workloadVersion,
      submission.scoringVersion,
      submission.referenceSetVersion,
      submission.proposedScore,
      submission.completedAt,
      submission.completedOn,
      submittedAt,
      submission.appVersion,
      submission.appBuild,
      submission.conditions.confidence,
      JSON.stringify(submission.metrics),
      submission.submissionId,
      requestHash,
      claimToken,
    ),
    env.DB.prepare(
      `UPDATE benchmark_v7_submissions AS submission
       SET entry_id = (
             SELECT entry.id FROM benchmark_v7_entries AS entry
             WHERE entry.installation_hash = ?1
               AND entry.workload_version = ?2
           ),
           response_status = CASE
             WHEN disposition = 'created' THEN 201 ELSE 200
           END,
           receipt_json = (
             SELECT json_object(
               'data', json_object(
                 'id', entry.id,
                 'rank', 1 + (
                   SELECT COUNT(*) FROM benchmark_v7_entries AS ahead
                   WHERE ahead.workload_version = entry.workload_version AND (
                     ahead.score > entry.score OR
                     (ahead.score = entry.score
                       AND ahead.completed_on < entry.completed_on) OR
                     (ahead.score = entry.score
                       AND ahead.completed_on = entry.completed_on
                       AND ahead.id < entry.id)
                   )
                 ),
                 'displayName', entry.display_name,
                 'computerModel', entry.computer_model,
                 'processorModel', entry.processor_model,
                 'memoryGB', entry.memory_gb,
                 'score', entry.score,
                 'workloadVersion', entry.workload_version,
                 'completedOn', entry.completed_on,
                 'confidence', entry.confidence
               ),
               'disposition', submission.disposition,
               'meta', json_object(
                 'submittedAt', ?3,
                 'planVersion', ?4,
                 'workloadVersion', ?5,
                 'scoringVersion', ?6,
                 'referenceSetVersion', ?7
               )
             )
             FROM benchmark_v7_entries AS entry
             WHERE entry.installation_hash = ?1
               AND entry.workload_version = ?2
           )
       WHERE submission_id = ?8 AND request_hash = ?9
         AND claim_token = ?10 AND receipt_json IS NULL
         AND disposition IS NOT NULL
         AND EXISTS (
           SELECT 1 FROM benchmark_v7_entries
           WHERE installation_hash = ?1 AND workload_version = ?2
         )`,
    ).bind(
      installationHash,
      submission.workloadVersion,
      submittedAt,
      V2_PLAN_VERSION,
      V2_WORKLOAD_VERSION,
      V2_SCORING_VERSION,
      V2_REFERENCE_SET_VERSION,
      submission.submissionId,
      requestHash,
      claimToken,
    ),
    env.DB.prepare(
      `SELECT request_hash, receipt_json, response_status
       FROM benchmark_v7_submissions WHERE submission_id = ?1`,
    ).bind(submission.submissionId),
  ]);
  const ledger = results[3]?.results[0] as SubmissionLedgerRow | undefined;
  if (!ledger) {
    throw new V2APIError(
      409,
      "submission_superseded_by_removal",
      "该成绩早于最近一次删除操作，未重新公开",
    );
  }
  return v2LedgerResponse(ledger, requestHash);
}

async function retainedV2SubmissionReplay(
  env: V2Env,
  submissionID: string,
  requestHash: string,
  now: Date,
): Promise<Response | null> {
  const cutoff = new Date(
    now.getTime()
      - V2_SUBMISSION_RECEIPT_RETENTION_DAYS * 24 * 60 * 60 * 1_000,
  ).toISOString();
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM benchmark_v7_submissions WHERE created_at < ?1`,
    ).bind(cutoff),
    env.DB.prepare(
      `SELECT request_hash, receipt_json, response_status
       FROM benchmark_v7_submissions WHERE submission_id = ?1`,
    ).bind(submissionID),
  ]);
  const ledger = results[1]?.results[0] as SubmissionLedgerRow | undefined;
  return ledger ? v2LedgerResponse(ledger, requestHash) : null;
}

async function replayV2Submission(
  env: V2Env,
  submissionID: string,
  requestHash: string,
): Promise<Response> {
  const ledger = await env.DB.prepare(
    `SELECT request_hash, receipt_json, response_status
     FROM benchmark_v7_submissions WHERE submission_id = ?1`,
  )
    .bind(submissionID)
    .first<SubmissionLedgerRow>();
  if (!ledger) {
    throw new V2APIError(
      409,
      "submission_superseded_by_removal",
      "该成绩早于最近一次删除操作，未重新公开",
    );
  }
  return v2LedgerResponse(ledger, requestHash);
}

function v2LedgerResponse(
  ledger: SubmissionLedgerRow,
  requestHash: string,
): Response {
  if (ledger.request_hash !== requestHash) {
    throw new V2APIError(
      409,
      "submission_id_conflict",
      "submissionId 已用于不同请求",
    );
  }
  if (
    ledger.receipt_json === null
    || (ledger.response_status !== 200 && ledger.response_status !== 201)
  ) {
    throw new V2APIError(
      409,
      "submission_in_progress",
      "相同 submissionId 的请求仍在处理中",
      undefined,
      { "Retry-After": "1" },
    );
  }
  try {
    JSON.parse(ledger.receipt_json);
  } catch {
    throw new Error("Stored V7 receipt is invalid");
  }
  return v2JSONText(
    ledger.receipt_json,
    ledger.response_status,
    { "Cache-Control": "no-store" },
  );
}

async function deleteV2Score(
  request: Request,
  env: V2Env,
  now: Date,
): Promise<Response> {
  await enforceV2IPRateLimit(request, env);
  const deletion = validateV2Deletion(await readV2JSONBody(request));
  const installationHash = await v2InstallationHash(env, deletion.installationId);
  await enforceV2InstallationRateLimit(env, installationHash);
  const deletedAt = now.toISOString();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO benchmark_v7_deletions (
         installation_hash, workload_version, deleted_at
       ) VALUES (?1, ?2, ?3)
       ON CONFLICT (installation_hash, workload_version)
       DO UPDATE SET deleted_at = CASE
         WHEN excluded.deleted_at > benchmark_v7_deletions.deleted_at
           THEN excluded.deleted_at
         ELSE benchmark_v7_deletions.deleted_at
       END`,
    ).bind(installationHash, deletion.workloadVersion, deletedAt),
    env.DB.prepare(
      `DELETE FROM benchmark_v7_submissions
       WHERE installation_hash = ?1 AND workload_version = ?2`,
    ).bind(installationHash, deletion.workloadVersion),
    env.DB.prepare(
      `DELETE FROM benchmark_v7_entries
       WHERE installation_hash = ?1 AND workload_version = ?2`,
    ).bind(installationHash, deletion.workloadVersion),
  ]);
  return v2JSON({
    data: { deleted: true },
    meta: {
      deletedAt,
      ...v2VersionMetadata(),
    },
  }, 200, { "Cache-Control": "no-store" });
}

async function v2InstallationHash(
  env: V2Env,
  installationID: string,
): Promise<string> {
  try {
    assertHMACSecret(env.IDENTITY_HMAC_KEY);
  } catch {
    throw new V2APIError(
      503,
      "write_protection_unavailable",
      "排行榜写入保护尚未配置",
    );
  }
  return await hmacHex(
    env.IDENTITY_HMAC_KEY,
    `leaderboard-installation-v2:${installationID}`,
  );
}

async function enforceV2IPRateLimit(
  request: Request,
  env: V2Env,
): Promise<void> {
  const limiter = v2RateLimiter(env);
  const ip = request.headers.get("CF-Connecting-IP")?.trim();
  if (!ip || ip.length > 128) {
    throw new V2APIError(
      503,
      "write_protection_unavailable",
      "排行榜写入保护尚未配置",
    );
  }
  try {
    const ipHash = await hmacHex(
      env.IDENTITY_HMAC_KEY,
      `leaderboard-ip-v2:${ip}`,
    );
    const ipRate = await limiter.limit({ key: `v2:ip:${ipHash}` });
    if (!ipRate.success) throw rateLimitedError();
  } catch (error) {
    if (error instanceof V2APIError) throw error;
    throw new V2APIError(
      503,
      "write_protection_unavailable",
      "排行榜写入保护暂时不可用",
    );
  }
}

async function enforceV2InstallationRateLimit(
  env: V2Env,
  installationHash: string,
): Promise<void> {
  const limiter = v2RateLimiter(env);
  let installationRate: Awaited<ReturnType<RateLimit["limit"]>>;
  try {
    installationRate = await limiter.limit({
      key: `v2:installation:${installationHash}`,
    });
  } catch {
    throw new V2APIError(
      503,
      "write_protection_unavailable",
      "排行榜写入保护暂时不可用",
    );
  }
  if (!installationRate.success) throw rateLimitedError();
}

function v2RateLimiter(env: V2Env): RateLimit {
  try {
    assertHMACSecret(env.IDENTITY_HMAC_KEY);
  } catch {
    throw new V2APIError(
      503,
      "write_protection_unavailable",
      "排行榜写入保护尚未配置",
    );
  }
  const limiter = env.SUBMISSION_RATE_LIMITER;
  if (!limiter) {
    throw new V2APIError(
      503,
      "write_protection_unavailable",
      "排行榜写入保护尚未配置",
    );
  }
  return limiter;
}

function rateLimitedError(): V2APIError {
  return new V2APIError(
    429,
    "rate_limited",
    "操作过于频繁，请稍后重试",
    undefined,
    { "Retry-After": "60" },
  );
}

async function readV2JSONBody(request: Request): Promise<unknown> {
  const mediaType = request.headers.get("content-type")
    ?.split(";", 1)[0]?.trim().toLowerCase();
  if (mediaType !== "application/json") {
    throw new V2ValidationError("body", "unsupported_media_type");
  }
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > V2_MAX_REQUEST_BYTES) {
    try {
      await request.body?.cancel();
    } catch {
      // The security boundary is the rejection; cancellation is best effort.
    }
    throw new V2ValidationError("body", "payload_too_large");
  }
  const body = request.body;
  if (!body) throw new V2ValidationError("body");
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      byteCount += value.byteLength;
      if (byteCount > V2_MAX_REQUEST_BYTES) {
        try {
          await reader.cancel();
        } catch {
          // Rejection remains fail-closed even if the producer cannot cancel.
        }
        throw new V2ValidationError("body", "payload_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new V2ValidationError("body");
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new V2ValidationError("body");
  }
}

function v2PublicEntry(row: V2RankedRow): V2PublicEntry {
  return {
    id: row.id,
    rank: Number(row.rank),
    displayName: row.display_name,
    computerModel: row.computer_model,
    processorModel: row.processor_model,
    memoryGB: Number(row.memory_gb),
    score: Number(row.score),
    workloadVersion: row.workload_version,
    completedOn: row.completed_on,
    confidence: row.confidence,
  };
}

function v2VersionMetadata(): V2VersionMetadata {
  return {
    planVersion: V2_PLAN_VERSION,
    workloadVersion: V2_WORKLOAD_VERSION,
    scoringVersion: V2_SCORING_VERSION,
    referenceSetVersion: V2_REFERENCE_SET_VERSION,
  };
}

function parseV2Integer(
  value: string | null,
  fallback: number,
  minimum: number,
  maximum: number,
  field: string,
): number {
  if (value === null) return fallback;
  if (!/^\d+$/.test(value)) throw new V2ValidationError(field);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new V2ValidationError(field);
  }
  return number;
}

function v2JSON(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return v2JSONText(JSON.stringify(body), status, extraHeaders);
}

function v2JSONText(
  body: string,
  status: number,
  extraHeaders: Record<string, string>,
): Response {
  return new Response(body, {
    status,
    headers: {
      ...V2_JSON_HEADERS,
      ...v2CORSHeaders(),
      ...extraHeaders,
    },
  });
}

function v2Error(
  status: number,
  code: string,
  message: string,
  details?: Record<string, unknown>,
  headers: Record<string, string> = {},
): Response {
  return v2JSON({
    error: {
      code,
      message,
      ...(details ? { details } : {}),
    },
  }, status, { "Cache-Control": "no-store", ...headers });
}

function v2OptionsResponse(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      ...v2CORSHeaders(),
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
      "Access-Control-Max-Age": "86400",
      "X-Leaderboard-Schema": String(V2_API_SCHEMA_VERSION),
    },
  });
}

function v2AllowedMethods(pathname: string): string {
  return pathname === "/v2/submissions"
    ? "POST, DELETE, OPTIONS"
    : "GET, OPTIONS";
}

function v2CORSHeaders(): Record<string, string> {
  return { "Access-Control-Allow-Origin": "*" };
}
