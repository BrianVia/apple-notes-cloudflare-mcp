import assert from "node:assert/strict";
import { planPush } from "./src/index.ts";

const note = {
  folder: "Work",
  title: "Plan",
  created: "2026-01-01T00:00:00Z",
  updated: "2026-01-02T00:00:00Z",
  pinned: true,
  markdown: "---\ntitle: Plan\n---\n\n# Plan\n",
};
const first = await planPush([], [note]);
const next = await planPush(
  [...first.index, { ...first.index[0], id: "deleted" }],
  [note, { ...note, title: "Huge", markdown: "x".repeat(25 * 1024 * 1024 + 1) }, { ...note, markdown: "dupe" }],
);

assert.match(first.index[0].id, /^[0-9a-f]{16}$/);
assert.equal(next.index[0].id, first.index[0].id);
assert.deepEqual(next.deletes, ["note:deleted"]);
assert.equal(next.writes[0][0], `note:${first.index[0].id}`);
assert.deepEqual(next.skipped, [{ folder: "Work", title: "Huge" }, { folder: "Work", title: "Plan" }]);
assert.equal(next.writes.length, 1);
console.log("worker push diff ok");
