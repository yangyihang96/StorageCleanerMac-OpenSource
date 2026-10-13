/** Shared transport boundary; callers retain their protocol-specific errors. */
export async function readBoundedJSON(
  request: Request,
  maximumBytes: number,
  invalid: (reason?: "unsupported_media_type" | "payload_too_large") => Error,
): Promise<unknown> {
  const mediaType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (mediaType !== "application/json") throw invalid("unsupported_media_type");
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declared) && declared > maximumBytes) {
    void request.body?.cancel().catch(() => {});
    throw invalid("payload_too_large");
  }
  if (!request.body) throw invalid();
  const reader = request.body.getReader();
  // Preallocate only the fixed protocol limit; tiny chunks cannot grow a metadata array.
  const bytes = new Uint8Array(maximumBytes);
  let count = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.byteLength > maximumBytes - count) {
        // Stop reading immediately. A stalled transport cancellation must not
        // delay the protocol's size-limit response.
        void reader.cancel().catch(() => {});
        throw invalid("payload_too_large");
      }
      bytes.set(value, count);
      count += value.byteLength;
    }
  } finally {
    reader.releaseLock();
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, count))) as unknown;
  } catch {
    throw invalid();
  }
}
