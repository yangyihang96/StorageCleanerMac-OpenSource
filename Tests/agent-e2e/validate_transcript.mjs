// Checks recorded MCP conversations against the official JSON Schema of the
// revision they used: the envelope of every response, and the result type the
// method calls for. An independent reading of the protocol: AJV and the
// specification's own schema.json, not this project's validator.
// Usage: node validate_transcript.mjs <node_modules> <schema root> <version> <transcript.jsonl>...
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const [modules, schemaRoot, version, ...transcripts] = process.argv.slice(2);
const require = createRequire(join(modules, "noop.js"));
const schema = JSON.parse(readFileSync(join(schemaRoot, version, "schema.json"), "utf8"));
const modern = Boolean(schema.$defs);
const Ajv = modern ? require("ajv/dist/2020.js").default : require("ajv").default;
const addFormats = require("ajv-formats").default ?? require("ajv-formats");
const ajv = new Ajv({ strict: false, allErrors: true });
addFormats(ajv);
ajv.addSchema(schema, "mcp");
const definitions = schema.$defs ?? schema.definitions;
const pointer = modern ? "$defs" : "definitions";
const validators = new Map();
const validator = (name) => {
  if (!definitions[name]) throw new Error(`${version} has no definition ${name}`);
  if (!validators.has(name)) validators.set(name, ajv.compile({ $ref: `mcp#/${pointer}/${name}` }));
  return validators.get(name);
};

const resultFor = {
  initialize: "InitializeResult",
  "server/discover": "DiscoverResult",
  "tools/list": "ListToolsResult",
  "tools/call": "CallToolResult",
  ping: "EmptyResult",
};
const envelope = { result: definitions.JSONRPCResultResponse ? "JSONRPCResultResponse" : "JSONRPCResponse",
                   error: definitions.JSONRPCErrorResponse ? "JSONRPCErrorResponse" : "JSONRPCError" };

let checked = 0;
const counts = {};
const failures = [];
const check = (name, value, line) => {
  checked += 1;
  counts[name] = (counts[name] ?? 0) + 1;
  const validate = validator(name);
  if (!validate(value)) failures.push({ line, name, errors: validate.errors.slice(0, 4), value: JSON.stringify(value).slice(0, 300) });
};

for (const transcript of transcripts) {
  readFileSync(transcript, "utf8").split("\n").filter(Boolean).forEach((text, index) => {
    const { request, response } = JSON.parse(text);
    const line = `${transcript.split("/").pop()}:${index + 1} ${request.method ?? "(raw)"}`;
    if (response.error) {
      check(envelope.error, response, line);
    } else {
      check(envelope.result, response, line);
      const name = resultFor[request.method];
      if (name) check(name, response.result, line);
      else failures.push({ line, name: "?", errors: [`no result type for ${request.method}`] });
    }
  });
}
console.log(JSON.stringify({ version, checked, counts, failures }, null, 1));
process.exit(failures.length ? 1 : 0);
