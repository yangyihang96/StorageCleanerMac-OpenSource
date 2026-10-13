import { describe, expect, it } from "vitest";
import { readBoundedJSON } from "../src/bounded-json";

const failure = (reason?: string) => new Error(reason ?? "invalid_body");
function streamed(chunks: Uint8Array[], headers: Record<string, string> = {}) {
  let cancelled = false;
  let pulled = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      const chunk = chunks[pulled++];
      if (chunk) controller.enqueue(chunk); else controller.close();
    },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 });
  const request = new Request("https://example.test", {
    method: "POST", headers: { "content-type": "application/json", ...headers },
    body, duplex: "half",
  } as RequestInit);
  return { request, cancelled: () => cancelled, pulled: () => pulled };
}
describe("bounded JSON transport used by both protocols", () => {
  it("accepts UTF-8 split within a multibyte character and JSON parameters", async () => {
    const bytes = new TextEncoder().encode('{"name":"测"}');
    const fixture = streamed([bytes.subarray(0, 10), bytes.subarray(10)], { "content-type": "Application/JSON; charset=utf-8" });
    expect(await readBoundedJSON(fixture.request, 64, failure)).toEqual({ name: "测" });
  });
  it.each([{}, { "content-length": "1" }])("stops an oversized stream regardless of declared length %j", async headers => {
    const fixture = streamed([new Uint8Array(8), new Uint8Array(9), new Uint8Array(1_000_000)], headers);
    await expect(readBoundedJSON(fixture.request, 16, failure)).rejects.toThrow("payload_too_large");
    expect(fixture.cancelled()).toBe(true);
    expect(fixture.pulled()).toBe(2);
  });
  it("rejects a large declared size before pulling", async () => {
    const fixture = streamed([new Uint8Array(99)], { "content-length": "99" });
    await expect(readBoundedJSON(fixture.request, 16, failure)).rejects.toThrow("payload_too_large");
    expect(fixture.pulled()).toBe(0);
    expect(fixture.cancelled()).toBe(true);
  });
  it("rejects lookalike content types", async () => {
    const fixture = streamed([new TextEncoder().encode("{}")], { "content-type": "application/json-extra" });
    await expect(readBoundedJSON(fixture.request, 16, failure)).rejects.toThrow("unsupported_media_type");
  });
  it("returns the size error even if transport cancellation never resolves", async () => {
    const body = new ReadableStream<Uint8Array>({
      pull(controller) { controller.enqueue(new Uint8Array(17)); },
      cancel() { return new Promise<void>(() => {}); },
    }, { highWaterMark: 0 });
    const request = new Request("https://example.test", {
      method: "POST", headers: { "content-type": "application/json" },
      body, duplex: "half",
    } as RequestInit);
    await expect(readBoundedJSON(request, 16, failure)).rejects.toThrow("payload_too_large");
  });
  it("rejects malformed UTF-8 instead of replacing bytes", async () => {
    const fixture = streamed([new Uint8Array([34, 0xff, 34])]);
    await expect(readBoundedJSON(fixture.request, 16, failure)).rejects.toThrow("invalid_body");
  });
  it("accepts the exact byte boundary and many tiny chunks", async () => {
    const bytes = new TextEncoder().encode('{"ok":true}');
    const fixture = streamed(Array.from(bytes, x => new Uint8Array([x])));
    expect(await readBoundedJSON(fixture.request, bytes.length, failure)).toEqual({ ok: true });
  });
});
