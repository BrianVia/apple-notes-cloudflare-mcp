import { Hono } from "hono";

interface Env {
  NOTES: KVNamespace;
  API_TOKEN: string;
}

export interface PushNote {
  folder: string;
  title: string;
  created: string;
  updated: string;
  pinned: boolean;
  markdown: string;
}

export interface IndexEntry {
  id: string;
  folder: string;
  title: string;
  updated: string;
  pinned: boolean;
  size: number;
}

const MAX_NOTE_BYTES = 25 * 1024 * 1024;
const encoder = new TextEncoder();

function isPushNote(value: unknown): value is PushNote {
  if (!value || typeof value !== "object") return false;
  const note = value as Record<string, unknown>;
  return (
    typeof note.folder === "string" &&
    typeof note.title === "string" &&
    typeof note.created === "string" &&
    typeof note.updated === "string" &&
    typeof note.pinned === "boolean" &&
    typeof note.markdown === "string"
  );
}

async function noteId(note: Pick<PushNote, "folder" | "title">): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", encoder.encode(`${note.folder}/${note.title}`));
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 16);
}

export async function planPush(oldIndex: IndexEntry[], notes: PushNote[]) {
  const index: IndexEntry[] = [];
  const writes: Array<[string, string]> = [];
  const skipped: Array<{ folder: string; title: string }> = [];

  for (const note of notes) {
    const size = encoder.encode(note.markdown).byteLength;
    if (size > MAX_NOTE_BYTES) {
      skipped.push({ folder: note.folder, title: note.title });
      continue;
    }
    const id = await noteId(note);
    // Same folder+title → same id; keep the first, report the rest.
    if (index.some((entry) => entry.id === id)) {
      skipped.push({ folder: note.folder, title: note.title });
      continue;
    }
    index.push({
      id,
      folder: note.folder,
      title: note.title,
      updated: note.updated,
      pinned: note.pinned,
      size,
    });
    writes.push([`note:${id}`, note.markdown]);
  }

  const currentIds = new Set(index.map((note) => note.id));
  const deletes = oldIndex
    .filter((note) => !currentIds.has(note.id))
    .map((note) => `note:${note.id}`);
  return { index, writes, deletes, skipped };
}

const app = new Hono<{ Bindings: Env }>();

app.use("*", async (c, next) => {
  if (!c.env.API_TOKEN || c.req.header("Authorization") !== `Bearer ${c.env.API_TOKEN}`) {
    return c.json({ error: "unauthorized" }, 401);
  }
  await next();
});

app.put("/notes", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "body must be JSON" }, 400);
  }
  if (!Array.isArray(body) || !body.every(isPushNote)) {
    return c.json({ error: "body must be an array of notes" }, 400);
  }

  const stored = await c.env.NOTES.get<unknown>("index", "json");
  const oldIndex = Array.isArray(stored) ? (stored as IndexEntry[]) : [];
  const plan = await planPush(oldIndex, body);
  await Promise.all(plan.writes.map(([key, markdown]) => c.env.NOTES.put(key, markdown)));
  await c.env.NOTES.put("index", JSON.stringify(plan.index));
  await Promise.all(plan.deletes.map((key) => c.env.NOTES.delete(key)));

  return c.json({ count: plan.index.length, deleted: plan.deletes.length, skipped: plan.skipped });
});

app.get("/notes", async (c) => {
  const index = await c.env.NOTES.get("index");
  return new Response(index ?? "[]", { headers: { "Content-Type": "application/json" } });
});

app.get("/notes/:id", async (c) => {
  const markdown = await c.env.NOTES.get(`note:${c.req.param("id")}`);
  return markdown === null
    ? c.json({ error: "not found" }, 404)
    : new Response(markdown, { headers: { "Content-Type": "text/markdown; charset=utf-8" } });
});

export default app;
