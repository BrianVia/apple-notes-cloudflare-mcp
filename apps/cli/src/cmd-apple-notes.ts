import { Command } from "commander";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import url from "node:url";
import { spawnSync } from "node:child_process";
import kleur from "kleur";
import TurndownService from "turndown";
import { info, success, die } from "./output";

// ─── The Apple Notes "dump" format ───────────────────────────────────────────
//
// A hierarchical directory of Markdown files, one per note, with YAML
// front-matter for metadata that doesn't fit in the body. This is the
// canonical shape `nk import` consumes — anyone can produce it from any
// source (not just Apple Notes) and feed it in.
//
//   <dir>/
//   ├── .notekeeper-dump.json        # manifest: version + counts
//   ├── <Folder Name>/               # mirrors folder tree 1:1
//   │   └── <sub-folder>/
//   │       └── <Note Title>.md
//   └── _unfiled/                    # notes not in any folder
//       └── <Note Title>.md
//
// Each .md file:
//
//   ---
//   title: Groceries
//   created: 2024-11-15T14:22:00Z
//   updated: 2026-04-10T09:15:00Z
//   pinned: false
//   source: apple-notes
//   source_id: x-coredata://...      # optional, for round-trip reference
//   ---
//
//   # Groceries
//   - [ ] Eggs
//   - [x] Milk

export interface DumpManifest {
  version: 1;
  source: string;             // "apple-notes", "evernote-enex", etc.
  exported_at: string;        // ISO timestamp
  note_count: number;
  folder_count: number;
}

export interface NoteFrontmatter {
  title: string;
  created: string;            // ISO 8601
  updated: string;            // ISO 8601
  pinned?: boolean;
  source?: string;
  source_id?: string;
  tags?: string[];
}

export function registerAppleNotesCommands(program: Command) {
  program
    .command("export-apple-notes <output-dir>")
    .description("Export Apple Notes.app into a notekeeper-dump directory")
    .option("--include-locked", "Attempt to include password-protected notes (will fail on any)")
    .option("--limit <n>", "Stop after N notes (for testing)", (v) => Number(v))
    .action(async (outDir: string, opts: { includeLocked?: boolean; limit?: number }) => {
      await exportAppleNotes(outDir, opts);
    });
}

/** Main export entry point. Keeps the public surface small so the import
 *  command can reuse the dump shape without touching AppleScript. */
export async function exportAppleNotes(
  outDir: string,
  opts: { includeLocked?: boolean; limit?: number } = {},
): Promise<void> {
  if (process.platform !== "darwin") {
    die("export-apple-notes requires macOS (Notes.app via AppleScript)");
  }

  const absOut = path.resolve(outDir);
  fs.mkdirSync(absOut, { recursive: true });

  info(`Reading from Notes.app via AppleScript — this can take a minute for large libraries…`);
  const raw = runAppleScriptDump({ includeLocked: !!opts.includeLocked, limit: opts.limit ?? 0 });
  const notes = parseDump(raw);
  info(`Got ${kleur.cyan(String(notes.length))} notes from Apple Notes.`);

  const turndown = new TurndownService({
    headingStyle: "atx",
    bulletListMarker: "-",
    codeBlockStyle: "fenced",
  });
  // Apple Notes encodes checklists as `<ul class="checklist"><li><input
  // type="checkbox" checked>text</li></ul>`. Default turndown loses the
  // checkbox state; override to produce GFM task-list syntax so our
  // renderer can show them as checkboxes on import.
  // Apple Notes nodes are not real DOM nodes — turndown wraps them via JSDOM
  // at runtime but we don't pull in DOM type defs. `any` keeps us out of
  // lib.dom.d.ts territory without adding types in tsconfig.
  // Drop inline data: URIs (base64-encoded images from Apple Notes). They
  // blow through D1's 1 MiB row limit and belong in R2 via the attachments
  // API anyway — roadmap P1. For now, replace with a visible placeholder.
  turndown.addRule("dataImage", {
    filter: (node: any) =>
      node.nodeName === "IMG" &&
      typeof node.getAttribute === "function" &&
      (node.getAttribute("src") ?? "").startsWith("data:"),
    replacement: () => "_[image removed during import]_",
  });

  turndown.addRule("checklist", {
    filter: (node: any) =>
      node.nodeName === "LI" &&
      node.parentNode != null &&
      typeof node.parentNode.getAttribute === "function" &&
      (node.parentNode.getAttribute("class") ?? "").split(/\s+/).includes("checklist"),
    replacement: (content: string, node: any) => {
      const input = typeof node.querySelector === "function"
        ? node.querySelector("input[type=checkbox]")
        : null;
      const checked = input?.hasAttribute?.("checked") ?? false;
      return `- [${checked ? "x" : " "}] ${content.trim()}\n`;
    },
  });

  const folderNames = new Set<string>();
  let written = 0;
  for (const note of notes) {
    const folder = note.folder || "_unfiled";
    const folderPath = folder
      .split("/")
      .map(sanitizeFilename)
      .join(path.sep);
    if (folder !== "_unfiled") folderNames.add(folder);

    const dir = path.join(absOut, folderPath);
    fs.mkdirSync(dir, { recursive: true });

    const markdown = coalesceHeadings(turndown.turndown(note.body_html), note.title);
    const front: NoteFrontmatter = {
      title: note.title,
      // AppleScript emits local-tz naive strings; Bun/Node's Date constructor
      // interprets those as local time. toISOString() then gives us a proper
      // UTC string with the Z suffix that Zod's z.string().datetime() expects.
      created: toUtcIso(note.created),
      updated: toUtcIso(note.updated),
      pinned: note.pinned,
      source: "apple-notes",
    };
    const md = buildMarkdownFile(front, markdown);
    const filename = uniqueFilename(dir, sanitizeFilename(note.title || "Untitled") + ".md");
    fs.writeFileSync(path.join(dir, filename), md, "utf8");
    written++;
  }

  const manifest: DumpManifest = {
    version: 1,
    source: "apple-notes",
    exported_at: new Date().toISOString(),
    note_count: written,
    folder_count: folderNames.size,
  };
  fs.writeFileSync(
    path.join(absOut, ".notekeeper-dump.json"),
    JSON.stringify(manifest, null, 2) + "\n",
    "utf8",
  );

  success(
    `Wrote ${kleur.bold(String(written))} notes across ${kleur.bold(String(folderNames.size))} folders to ${absOut}`,
  );
  info(`Import with: ${kleur.cyan(`nk import ${absOut}`)}`);
}

// ─── AppleScript ─────────────────────────────────────────────────────────────

interface RawNote {
  folder: string;     // "" when unfiled; "Work/Meetings" for nested
  title: string;
  body_html: string;
  created: string;    // ISO
  updated: string;    // ISO
  pinned: boolean;
}

/** Run the external AppleScript dump file, return its stdout (the path to
 *  the temp dump file the script wrote). Keeping the AppleScript as a real
 *  `.applescript` file on disk makes it debuggable independently and avoids
 *  encoding/escaping issues from jamming it into a TS template literal. */
function runAppleScriptDump(opts: { includeLocked: boolean; limit: number }): string {
  // The .applescript sibling file. When running `bun run src/index.ts …`
  // this resolves to apps/cli/src/. When the bundled `dist/nk.js` runs, we
  // need the file to travel with the bundle; see post-build copy in
  // package.json `build` script.
  const here = path.dirname(url.fileURLToPath(import.meta.url));
  const scriptPath = path.join(here, "apple-notes-dump.applescript");
  if (!fs.existsSync(scriptPath)) {
    die(`AppleScript not found at ${scriptPath}`);
  }

  const res = spawnSync(
    "osascript",
    [scriptPath, String(opts.limit), opts.includeLocked ? "true" : "false"],
    { encoding: "utf8", maxBuffer: 1024 * 1024 * 32 },
  );
  if (res.error) die(`osascript failed: ${res.error.message}`);
  if (res.status !== 0) {
    die(`osascript exited ${res.status}: ${res.stderr?.trim() || "(no stderr)"}`);
  }

  const dumpPath = res.stdout.trim();
  if (!dumpPath || !fs.existsSync(dumpPath)) {
    die(`AppleScript didn't produce a dump file (got '${dumpPath}')`);
  }
  const raw = fs.readFileSync(dumpPath, "utf8");
  try { fs.unlinkSync(dumpPath); } catch { /* fine if gone */ }
  return raw;
}

function parseDump(raw: string): RawNote[] {
  const FS = String.fromCharCode(0x1f);  // Unit Separator
  const RS = String.fromCharCode(0x1e);  // Record Separator
  // Strip a trailing newline osascript's `return` adds, then split on RS.
  const records = raw.split(RS).map((r) => r.replace(/^\n+|\n+$/g, "")).filter((r) => r.length > 0);
  const notes: RawNote[] = [];
  for (const rec of records) {
    const fields = rec.split(FS);
    if (fields.length < 6) continue; // malformed
    const [folder, title, created, updated, pinnedText, ...bodyParts] = fields;
    // If the note body itself contained a FS char (shouldn't, but belt-and-
    // suspenders), re-join with FS so content is preserved.
    const body_html = bodyParts.join(FS);
    notes.push({
      folder: folder ?? "",
      title: title ?? "",
      body_html: body_html ?? "",
      created: created ?? "",
      updated: updated ?? "",
      pinned: pinnedText === "true",
    });
  }
  return notes;
}

// ─── Dump file helpers ──────────────────────────────────────────────────────

/** Serialize front matter + markdown body. */
export function buildMarkdownFile(front: NoteFrontmatter, body: string): string {
  const yaml: string[] = ["---"];
  yaml.push(`title: ${quoteYaml(front.title)}`);
  yaml.push(`created: ${front.created}`);
  yaml.push(`updated: ${front.updated}`);
  if (front.pinned != null) yaml.push(`pinned: ${front.pinned}`);
  if (front.source) yaml.push(`source: ${front.source}`);
  if (front.source_id) yaml.push(`source_id: ${quoteYaml(front.source_id)}`);
  if (front.tags && front.tags.length > 0) {
    yaml.push(`tags: [${front.tags.map(quoteYaml).join(", ")}]`);
  }
  yaml.push("---", "");
  return yaml.join("\n") + "\n" + body.replace(/\n+$/, "") + "\n";
}

/** Parse a dump `.md` file into its front matter + body. */
export function parseMarkdownFile(raw: string): { front: NoteFrontmatter; body: string } {
  const fmMatch = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
  if (!fmMatch) {
    // No front matter → treat as title-less note.
    return {
      front: {
        title: "",
        created: new Date().toISOString(),
        updated: new Date().toISOString(),
      },
      body: raw,
    };
  }
  const yaml = fmMatch[1]!;
  const body = raw.slice(fmMatch[0].length).replace(/^\n+/, "");
  const front: Partial<NoteFrontmatter> = {};
  for (const line of yaml.split(/\r?\n/)) {
    const m = line.match(/^(\w+):\s*(.*)$/);
    if (!m) continue;
    const [, key, value] = m;
    if (!key) continue;
    switch (key) {
      case "title":
      case "created":
      case "updated":
      case "source":
      case "source_id":
        (front as Record<string, unknown>)[key] = unquoteYaml(value ?? "");
        break;
      case "pinned":
        front.pinned = (value ?? "").trim() === "true";
        break;
      case "tags":
        front.tags = parseYamlArray(value ?? "");
        break;
    }
  }
  return {
    front: {
      title: front.title ?? "",
      created: front.created ?? new Date().toISOString(),
      updated: front.updated ?? new Date().toISOString(),
      pinned: front.pinned,
      source: front.source,
      source_id: front.source_id,
      tags: front.tags,
    },
    body,
  };
}

function quoteYaml(s: string): string {
  if (/^[A-Za-z0-9 \-_./]*$/.test(s) && s.length > 0) return s;
  // Use double-quoted string, escape backslashes and quotes.
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function unquoteYaml(s: string): string {
  const trimmed = s.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
  return trimmed;
}

function parseYamlArray(s: string): string[] {
  const m = s.trim().match(/^\[(.*)\]$/);
  if (!m) return [];
  return m[1]!
    .split(",")
    .map((x) => unquoteYaml(x.trim()))
    .filter((x) => x.length > 0);
}

/** Merge consecutive same-level ATX headings into a single heading and drop
 *  empty heading lines. Apple Notes' attributed-string runs (introduced by
 *  spell-check, autocorrect, or piecemeal edits) get serialized as multiple
 *  adjacent `<hN>` blocks for what visually was one heading; turndown turns
 *  those into a stack of separate `# Foo` / `# bar` lines. Re-stitching them
 *  here is safe because legitimate Markdown almost never repeats the same
 *  heading level back-to-back with only blank lines between.
 *
 *  When `knownTitle` is provided, the first coalesced heading is compared to
 *  it (whitespace-insensitive); if they match, the original title text is
 *  used verbatim. Necessary because run-splits sometimes occur on word
 *  boundaries — concatenation alone produces "BrookeChristmas" from
 *  ["B","rooke","Christmas"] when the actual title is "Brooke Christmas". */
export function coalesceHeadings(md: string, knownTitle?: string): string {
  const lines = md.split("\n");
  const out: string[] = [];
  const headingRe = /^(#{1,6})\s+(.*?)\s*$/;
  let i = 0;
  let firstHeadingHandled = false;
  while (i < lines.length) {
    const m = lines[i]!.match(headingRe);
    if (!m) {
      out.push(lines[i]!);
      i++;
      continue;
    }
    const level = m[1]!.length;
    const pieces: string[] = [m[2]!];
    let cursor = i + 1;
    while (cursor < lines.length) {
      let scan = cursor;
      while (scan < lines.length && lines[scan]!.trim() === "") scan++;
      if (scan >= lines.length) break;
      const next = lines[scan]!.match(headingRe);
      if (!next || next[1]!.length !== level) break;
      pieces.push(next[2]!);
      cursor = scan + 1;
    }
    // Concatenate pieces verbatim so internal whitespace within a chunk is
    // preserved ("ke car" stays "ke car"), then collapse runs of whitespace
    // and trim. Empty merged headings are dropped entirely — they're an
    // artifact of attribute-only runs in the source HTML.
    let merged = pieces.join("").replace(/\s+/g, " ").trim();
    if (!firstHeadingHandled && knownTitle && merged.length > 0) {
      const norm = (s: string) => s.replace(/\s+/g, "").toLowerCase();
      if (norm(merged) === norm(knownTitle)) merged = knownTitle;
      firstHeadingHandled = true;
    }
    if (merged.length > 0) {
      if (out.length > 0 && out[out.length - 1] !== "") out.push("");
      out.push(`${"#".repeat(level)} ${merged}`);
      out.push("");
    }
    i = cursor;
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n");
}

/** Sanitize a string into a filesystem-safe path component. Matches Apple's
 *  own cleanFileName logic (no `/` or `:`, capped at 200 chars). */
function sanitizeFilename(name: string): string {
  let s = name.replace(/[/:\\?*|<>"]/g, "-").trim();
  if (s.length === 0) s = "Untitled";
  if (s.length > 200) s = s.slice(0, 200);
  return s;
}

/** Accepts naive local-time strings (e.g., `"2023-12-02T14:18:26"`) or already-
 *  UTC-qualified strings and returns a UTC ISO-8601 string with a Z suffix.
 *  Returns `now` on anything unparseable. */
function toUtcIso(s: string): string {
  const d = new Date(s);
  if (isNaN(d.getTime())) return new Date().toISOString();
  return d.toISOString();
}

function uniqueFilename(dir: string, filename: string): string {
  if (!fs.existsSync(path.join(dir, filename))) return filename;
  const ext = path.extname(filename);
  const base = filename.slice(0, -ext.length);
  for (let i = 2; i < 1000; i++) {
    const candidate = `${base} (${i})${ext}`;
    if (!fs.existsSync(path.join(dir, candidate))) return candidate;
  }
  return filename; // give up, overwrite
}
