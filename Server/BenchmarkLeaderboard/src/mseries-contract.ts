/** New protocol: deliberately disabled for production submissions until audited
 * independent Release calibration and its database migration are available.
 * No bundled synthetic reference and no fallback to the legacy v2 leaderboard. */
export const MSERIES = {
  schema: "mseries-result-v10-draft2",
  plan: "mseries-core18-v10-draft2",
  workload: "mseries-fixed-kernels-v1",
  fixture: "procedural-mit-seed-619a27de-v1",
  implementation: "native-c-metal-posix-v1",
  statistics: "median-mad-all-samples-v1",
  scoring: "weighted-geomean-20-20-25-20-15-draft1",
  contractHash: "c8b75dff7897d6ff8055d51fdf37afce20d1b656037e042a98c68e03e9083318",
} as const;

export const M_GROUPS = [
  { weight: .20, ids: ["integer", "floating", "compression", "image"].map(x => `cpu.single.${x}`) },
  { weight: .20, ids: ["integer", "floating", "compression", "image"].map(x => `cpu.multi.${x}`) },
  { weight: .25, ids: ["gpu.graphics.offscreen", "gpu.compute.fp32", "gpu.compute.fp16"] },
  { weight: .20, ids: ["memory.copy", "memory.triad", "memory.pointerChase"] },
  { weight: .15, ids: ["storage.seqRead", "storage.seqWrite", "storage.randomReadQD1", "storage.randomWriteQD1"] },
] as const;
export const M_CORE_IDS = M_GROUPS.flatMap(x => x.ids);

export interface MReference {
  contractHash: string;
  version: string;
  /** Audit artifact digest, not an assertion of hardware authentication. */
  evidenceSHA256: string;
  independentReleaseSessionIDs: string[];
  medians: Record<string, number>;
}
export interface MSubmission {
  submissionID: string;
  installationID: string;
  displayName: string;
  contractHash: string;
  referenceVersion: string;
  /** Exactly three validated repeat values per required Core, not I/O events. */
  samples: Record<string, number[]>;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const positive = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v > 0;
const record = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
function exactKeys(value: object, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return actual.length === keys.length && actual.every(x => keys.includes(x));
}

/** Unknown identity fields, paths, IP, serial, hostname and proposedScore are
 * rejected rather than silently stored. Raw app exports are NOT upload DTOs. */
export function validateMSubmission(input: unknown): MSubmission {
  if (!record(input) || !exactKeys(input, ["submissionID", "installationID", "displayName", "contractHash", "referenceVersion", "samples"])) throw new Error("invalid-fields");
  if (typeof input.submissionID !== "string" || !UUID.test(input.submissionID) ||
      typeof input.installationID !== "string" || !UUID.test(input.installationID) ||
      input.submissionID === input.installationID) throw new Error("invalid-random-identifiers");
  if (typeof input.displayName !== "string" || input.displayName.trim().length < 1 ||
      input.displayName.length > 32 || /[\u0000-\u001f\u007f/@\\:]/u.test(input.displayName)) throw new Error("invalid-display-name");
  if (input.contractHash !== MSERIES.contractHash || typeof input.referenceVersion !== "string") throw new Error("incompatible-protocol");
  if (!record(input.samples) || !exactKeys(input.samples, M_CORE_IDS)) throw new Error("incomplete-core");
  for (const values of Object.values(input.samples)) {
    if (!Array.isArray(values) || values.length !== 3 || !values.every(positive)) throw new Error("invalid-samples");
  }
  return input as unknown as MSubmission;
}

/** Server-side re-derivation. No supplied aggregate, chip-name bonus, clipping,
 * missing-group reweighting or synthetic production reference. */
export function recomputeMIndex(submission: MSubmission, reference: MReference): number {
  validateMSubmission(submission);
  const ids = reference.independentReleaseSessionIDs;
  if (reference.contractHash !== MSERIES.contractHash || reference.version !== submission.referenceVersion ||
      !/^[a-f0-9]{64}$/.test(reference.evidenceSHA256) || ids.length < 3 || new Set(ids).size !== ids.length ||
      !ids.every(x => UUID.test(x)) || !exactKeys(reference.medians, M_CORE_IDS) ||
      !Object.values(reference.medians).every(positive)) throw new Error("unvalidated-reference");
  let sum = 0;
  for (const group of M_GROUPS) for (const id of group.ids) {
    const median = [...submission.samples[id]!].sort((a, b) => a - b)[1]!;
    const baseline = reference.medians[id]!;
    const difference = id === "memory.pointerChase" ? Math.log(baseline) - Math.log(median) : Math.log(median) - Math.log(baseline);
    sum += difference * group.weight / group.ids.length;
  }
  const result = 1000 * Math.exp(sum);
  if (!positive(result)) throw new Error("non-finite-index");
  return result;
}

export function handleMSeriesRequest(request: Request, url: URL): Response {
  const headers = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" };
  if (url.pathname === "/v3/mseries/capabilities" && request.method === "GET") {
    return new Response(JSON.stringify({ ...MSERIES, acceptingSubmissions: false, reason: "reference-and-storage-not-activated" }), { headers });
  }
  // Intentionally do not parse or log identity-bearing request bodies while
  // inactive. Existing /v1 and /v2 deletion routes remain unchanged.
  return new Response(JSON.stringify({ code: "protocol_not_activated", acceptingSubmissions: false }), { status: 503, headers });
}
