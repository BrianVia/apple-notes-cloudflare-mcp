import { Command } from "commander";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import kleur from "kleur";
import { Client } from "./client";
import { requireConfig } from "./config";
import { die, info, out, relTime, success, table, truncate } from "./output";

export function registerNoteCommands(program: Command) {
  program
    .command("new")
    .description("Create a new note")
    .option("-t, --title <title>", "Note title (else derived from first line)")
    .option("-b, --body <markdown>", "Inline markdown body")
    .option("-f, --file <path>", "Read body from file ('-' for stdin)")
    .option("--folder <id>", "Folder id")
    .option("--tag <name>", "Tag (repeatable)", collect, [] as string[])
    .option("--pin", "Pin the note")
    .option("--json", "Output JSON")
    .action(async (opts) => {
      const client = new Client(requireConfig());
      const body = await readBody(opts);
      const note = await client.createNote({
        title: opts.title,
        body,
        folder_id: opts.folder ?? null,
        tags: opts.tag,
        pinned: !!opts.pin,
      });
      if (opts.json) return out(note, { json: true });
      success(`Created ${kleur.cyan(note.id)} — ${kleur.bold(note.title)}`);
    });

  program
    .command("ls")
    .alias("list")
    .description("List notes")
    .option("--folder <id>", "Filter by folder id")
    .option("--tag <name>", "Filter by tag")
    .option("-q, --query <text>", "FTS search")
    .option("--trashed", "Show trashed notes instead")
    .option("-n, --limit <n>", "Limit results", "50")
    .option("--json", "Output JSON")
    .action(async (opts) => {
      const client = new Client(requireConfig());
      const res = await client.listNotes({
        folder_id: opts.folder,
        tag: opts.tag,
        q: opts.query,
        trashed: opts.trashed,
        limit: Number(opts.limit),
      });
      if (opts.json) return out(res, { json: true });
      if (res.notes.length === 0) {
        info("(no notes)");
        return;
      }
      const rows = res.notes.map((n) => ({
        id: n.id.slice(0, 8),
        title: truncate(n.title || "(untitled)", 48),
        tags: n.tags.join(",") || kleur.gray("—"),
        updated: relTime(n.updated_at),
        pin: n.pinned ? "📌" : " ",
      }));
      table(rows, ["pin", "id", "title", "tags", "updated"]);
      if (res.next_cursor) info(`…more available. pass --cursor ${res.next_cursor}`);
    });

  program
    .command("get <id>")
    .description("Print a note's markdown body to stdout")
    .option("--meta", "Include metadata as a YAML front-matter-ish header")
    .option("--json", "Output JSON (metadata + body)")
    .action(async (id: string, opts) => {
      const client = new Client(requireConfig());
      const note = await client.getNote(await resolveId(client, id));
      if (opts.json) return out(note, { json: true });
      if (opts.meta) {
        process.stdout.write(`---\n`);
        process.stdout.write(`id: ${note.id}\n`);
        process.stdout.write(`title: ${note.title}\n`);
        process.stdout.write(`folder_id: ${note.folder_id ?? ""}\n`);
        process.stdout.write(`tags: [${note.tags.join(", ")}]\n`);
        process.stdout.write(`pinned: ${note.pinned}\n`);
        process.stdout.write(`updated_at: ${note.updated_at}\n`);
        process.stdout.write(`---\n\n`);
      }
      process.stdout.write(note.body);
      if (!note.body.endsWith("\n")) process.stdout.write("\n");
    });

  program
    .command("edit <id>")
    .description("Open note in $EDITOR and save on exit")
    .action(async (id: string) => {
      const client = new Client(requireConfig());
      const resolvedId = await resolveId(client, id);
      const note = await client.getNote(resolvedId);

      const editor = process.env.VISUAL || process.env.EDITOR || "vi";
      const tmp = path.join(os.tmpdir(), `notekeeper-${note.id}-${Date.now()}.md`);
      fs.writeFileSync(tmp, note.body, "utf8");
      const before = fs.statSync(tmp).mtimeMs;

      const result = spawnSync(editor, [tmp], { stdio: "inherit" });
      if (result.status !== 0) {
        fs.unlinkSync(tmp);
        die(`editor exited with code ${result.status}`);
      }

      const after = fs.statSync(tmp).mtimeMs;
      if (after === before) {
        fs.unlinkSync(tmp);
        info("No changes.");
        return;
      }
      const body = fs.readFileSync(tmp, "utf8");
      fs.unlinkSync(tmp);
      const updated = await client.updateNote(resolvedId, { body });
      success(`Saved — ${kleur.bold(updated.title)}`);
    });

  program
    .command("rm <id>")
    .description("Move a note to trash (or permanently delete with --hard)")
    .option("--hard", "Permanently delete")
    .action(async (id: string, opts) => {
      const client = new Client(requireConfig());
      const resolvedId = await resolveId(client, id);
      await client.deleteNote(resolvedId, !!opts.hard);
      success(opts.hard ? "Permanently deleted" : "Moved to trash");
    });

  program
    .command("restore <id>")
    .description("Restore a trashed note")
    .action(async (id: string) => {
      const client = new Client(requireConfig());
      const resolvedId = await resolveId(client, id);
      await client.restoreNote(resolvedId);
      success("Restored");
    });

  program
    .command("pin <id>")
    .description("Pin a note")
    .action(async (id: string) => {
      const client = new Client(requireConfig());
      const note = await client.updateNote(await resolveId(client, id), { pinned: true });
      success(`Pinned ${kleur.bold(note.title)}`);
    });

  program
    .command("unpin <id>")
    .description("Unpin a note")
    .action(async (id: string) => {
      const client = new Client(requireConfig());
      const note = await client.updateNote(await resolveId(client, id), { pinned: false });
      success(`Unpinned ${kleur.bold(note.title)}`);
    });
}

function collect<T>(value: T, previous: T[]): T[] {
  return [...previous, value];
}

async function readBody(opts: { body?: string; file?: string }): Promise<string> {
  if (opts.body !== undefined) return opts.body;
  if (!opts.file) return "";
  if (opts.file === "-") {
    return await readStdin();
  }
  return fs.readFileSync(opts.file, "utf8");
}

async function readStdin(): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolve(data));
  });
}

/**
 * Let users pass an 8-char prefix (the "short id" from `nk ls`) and resolve
 * it to a full id. Full 24-char ids pass through untouched.
 */
async function resolveId(client: Client, idOrPrefix: string): Promise<string> {
  if (/^[a-z0-9]{24}$/.test(idOrPrefix)) return idOrPrefix;
  if (!/^[a-z0-9]+$/.test(idOrPrefix) || idOrPrefix.length < 4) {
    die(`invalid id: ${idOrPrefix}`);
  }
  // No dedicated "get by prefix" endpoint — list a page and filter. For
  // small workspaces this is fine; we can add a server route later.
  const res = await client.listNotes({ limit: 200 });
  const matches = res.notes.filter((n) => n.id.startsWith(idOrPrefix));
  if (matches.length === 0) die(`no note matches prefix ${idOrPrefix}`);
  if (matches.length > 1) {
    die(`ambiguous prefix ${idOrPrefix} (${matches.length} matches); use a longer prefix`);
  }
  return matches[0]!.id;
}
