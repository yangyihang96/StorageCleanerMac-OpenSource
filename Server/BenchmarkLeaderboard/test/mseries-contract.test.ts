import { describe, expect, it } from "vitest";
import { M_CORE_IDS, MSERIES, recomputeMIndex, validateMSubmission, handleMSeriesRequest, type MReference, type MSubmission } from "../src/mseries-contract";
const uuid = (n: number) => `10000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
// Synthetic references are confined to this deterministic math test.
const reference: MReference = { contractHash: MSERIES.contractHash, version: "fixture-only", evidenceSHA256: "a".repeat(64),
  independentReleaseSessionIDs: [uuid(1), uuid(2), uuid(3)], medians: Object.fromEntries(M_CORE_IDS.map(id => [id, 1])) };
function submission(ratio = 1): MSubmission {
  return { submissionID: uuid(8), installationID: uuid(9), displayName: "Test Mac", contractHash: MSERIES.contractHash,
    referenceVersion: "fixture-only", samples: Object.fromEntries(M_CORE_IDS.map(id => [id, [1, 1, 1].map(() => id === "memory.pointerChase" ? 1 / ratio : ratio)])) };
}
describe("new MSeries protocol boundary", () => {
  it("recomputes all 18 metrics and does not clip ratios above five", () => {
    expect(M_CORE_IDS).toHaveLength(18);
    expect(recomputeMIndex(submission(), reference)).toBeCloseTo(1000);
    expect(recomputeMIndex(submission(12), reference)).toBeCloseTo(12000);
  });
  it("rejects incomplete Core and nonpositive/nonfinite raw values", () => {
    const request = submission(); delete request.samples[M_CORE_IDS[0]!];
    expect(() => validateMSubmission(request)).toThrow("incomplete-core");
    for (const bad of [0, -1, NaN, Infinity]) {
      const input = submission(); input.samples[M_CORE_IDS[0]!]![0] = bad;
      expect(() => validateMSubmission(input)).toThrow("invalid-samples");
    }
  });
  it("rejects private extras and client aggregates", () => {
    for (const key of ["proposedScore", "hostname", "serial", "path", "ip"]) {
      expect(() => validateMSubmission({ ...submission(), [key]: "do-not-store" })).toThrow("invalid-fields");
    }
  });
  it("rejects a time-based installation UUID", () => {
    expect(() => validateMSubmission({ ...submission(), installationID: "10000000-0000-1000-8000-000000000009" })).toThrow("invalid-random-identifiers");
  });
  it("requires a matching independent reference", () => {
    expect(() => recomputeMIndex(submission(), { ...reference, independentReleaseSessionIDs: [uuid(1), uuid(1), uuid(1)] })).toThrow("unvalidated-reference");
    expect(() => recomputeMIndex(submission(), { ...reference, contractHash: "legacy-v9" })).toThrow("unvalidated-reference");
  });
  it("keeps production submissions disabled without reading their bodies", async () => {
    const url = new URL("https://fixture.invalid/v3/mseries/submissions");
    const request = new Request(url, { method: "POST", body: "must-not-be-read" });
    expect(handleMSeriesRequest(request, url).status).toBe(503);
    expect(request.bodyUsed).toBe(false);
    const cap = new URL("https://fixture.invalid/v3/mseries/capabilities");
    expect(await handleMSeriesRequest(new Request(cap), cap).json()).toMatchObject({ acceptingSubmissions: false });
  });
});
