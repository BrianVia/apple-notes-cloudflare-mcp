import assert from "node:assert/strict";
import app, { dispatchMcp } from "./src/index.ts";

const index = [{ id: "abc", folder: "Work", title: "Plan", updated: "2026-01-02", pinned: true, size: 6 }];
const values = new Map([
  ["index", JSON.stringify(index)],
  ["note:abc", "# Plan"],
]);
const kv = { async get(key) { return values.get(key) ?? null; } };
const call = (id, method, params) => dispatchMcp({ jsonrpc: "2.0", id, method, params }, kv);

const initialized = await call(1, "initialize");
assert.equal(initialized.result.protocolVersion, "2025-06-18");
assert.deepEqual(initialized.result.capabilities, { tools: {} });
assert.equal(initialized.result.serverInfo.name, "apple-notes");

const tools = await call(2, "tools/list");
assert.deepEqual(tools.result.tools.map((tool) => tool.name), ["list_notes", "get_note"]);
assert.deepEqual(JSON.parse((await call(3, "tools/call", { name: "list_notes", arguments: {} })).result.content[0].text), index);
assert.equal((await call(4, "tools/call", { name: "get_note", arguments: { id: "abc" } })).result.content[0].text, "# Plan");

const missing = await call(5, "tools/call", { name: "get_note", arguments: { id: "missing" } });
assert.equal(missing.result.isError, true);
assert.match(missing.result.content[0].text, /missing/);
assert.equal((await call(6, "unknown")).error.code, -32601);
assert.equal(await call(undefined, "notifications/initialized"), null);

const env = { API_TOKEN: "secret", NOTES: kv };
const headers = { Authorization: "Bearer secret", "Content-Type": "application/json" };
const initializeResponse = await app.request("/mcp", {
  method: "POST",
  headers,
  body: JSON.stringify({ jsonrpc: "2.0", id: 7, method: "initialize" }),
}, env);
assert.equal(initializeResponse.status, 200);
assert.match(initializeResponse.headers.get("Content-Type"), /^application\/json/);
assert.equal((await initializeResponse.json()).result.serverInfo.name, "apple-notes");
assert.equal((await app.request("/mcp", { method: "GET", headers }, env)).status, 405);
assert.equal((await app.request("/mcp", { method: "POST" }, env)).status, 401);
assert.equal((await app.request("/mcp", {
  method: "POST",
  headers,
  body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
}, env)).status, 202);
console.log("mcp dispatch ok");
