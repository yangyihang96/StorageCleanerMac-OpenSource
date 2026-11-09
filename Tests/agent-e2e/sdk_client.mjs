// The official TypeScript MCP SDK as an independent client of the bridge.
// Usage: node sdk_client.mjs <dir of @modelcontextprotocol/sdk> <bridge path>
// Prints one JSON report. The SDK checks every response against its own
// schemas, and structured results against each tool's outputSchema.
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [sdk, bridge] = process.argv.slice(2);
const load = (file) => import(pathToFileURL(join(sdk, "dist/esm", file)).href);
const { Client } = await load("client/index.js");
const { StdioClientTransport } = await load("client/stdio.js");

const client = new Client({ name: "official-sdk-e2e", version: "1" });
await client.connect(new StdioClientTransport({ command: bridge, args: ["mcp"], stderr: "inherit" }));

const report = { serverVersion: client.getServerVersion() };
const { tools } = await client.listTools();
report.tools = tools.length;

const overview = await client.callTool({ name: "get_overview", arguments: {} });
if (overview.isError) {
  report.beforeApproval = overview.content[0].text.includes("approval_required");
} else {
  report.overview = overview.structuredContent.app.name;
  const results = await client.callTool({ name: "list_results", arguments: { module: "junk" } });
  report.results = results.structuredContent.items.length;
  try {
    await client.callTool({ name: "no_such_tool", arguments: {} });
  } catch (error) {
    report.unknownTool = error.code;
  }
}
await client.close();
console.log(JSON.stringify(report));
