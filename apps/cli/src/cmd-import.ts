import { Command } from "commander";
import fs from "node:fs";
import path from "node:path";
import kleur from "kleur";
import { Client } from "./client";
import { requireConfig } from "./config";
import { die, info, success } from "./output";
import { coalesceHeadings, parseMarkdownFile, type NoteFrontmatter } from "./cmd-apple-notes";

// Universal importer: consumes any directory that follows the dump shape
// documented in cmd-apple-notes.ts. Not Apple-Notes-specific — anything
// that produces `.md` files with YAML front matter + folder hierarchy
// can be imported (Obsidian vaults, Bear exports, hand-assembled dumps).

export function registerImportCommands(program: Command) {
  program
    .command("import <dump-dir>")
    .description("Import a directory of notes (notekeeper-dump format) into the API")
    .option("--dry-run", "Scan and report without uploading")
    .option("--concurrency <n>", "Parallel uploads", (v) => Number(v), 4)
    .option(
      "--include-trashed",
      "Include notes from 'Recently Deleted' (Apple Notes trash folder)",
    )
    .action(
      async (
        dir: string,
        opts: { dryRun?: boolean; concurrency: number; includeTrashed?: boolean },
      ) => {
        await importDump(dir, opts);
      },
    );
}

interface PendingNote {
  filePath: string;
  front: NoteFrontmatter;
  body: string;
  folder: string; // "" for unfiled
}

export async function importDump(
  dir: string,
  opts: { dryRun?: boolean; concurrency?: number; includeTrashed?: boolean } = {},
): Promise<void> {
  const absDir = path.resolve(dir);
  if (!fs.existsSync(absDir) || !fs.statSync(absDir).isDirectory()) {
    die(`not a directory: ${absDir}`);
  }

  // Manifest is optional — a hand-assembled dump doesn't need one — but
  // when present it tells us what we're importing.
  const manifestPath = path.join(absDir, ".notekeeper-dump.json");
  let source: string | undefined;
  if (fs.existsSync(manifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    source = manifest.source;
    info(`Manifest: source=${manifest.source} notes=${manifest.note_count} folders=${manifest.folder_count}`);
  } else {
    info(`No .notekeeper-dump.json manifest — treating ${absDir} as a raw notes directory.`);
  }

  let pending = collectNotes(absDir);
  // Apple Notes' "Recently Deleted" is their trash folder. Unless explicitly
  // asked for, skip it — those aren't notes the user wants resurrected.
  if (source === "apple-notes" && !opts.includeTrashed) {
    const before = pending.length;
    pending = pending.filter((n) => !n.folder.startsWith("Recently Deleted"));
    const skipped = before - pending.length;
    if (skipped > 0) {
      info(kleur.gray(`Skipping ${skipped} note(s) in 'Recently Deleted' (pass --include-trashed to include).`));
    }
  }
  info(`Found ${kleur.cyan(String(pending.length))} notes across ${countFolders(pending)} folders.`);

  if (opts.dryRun) {
    for (const n of pending.slice(0, 10)) {
      info(`  ${n.folder || "(unfiled)"}${n.folder ? "/" : ""}${n.front.title}`);
    }
    if (pending.length > 10) info(`  … ${pending.length - 10} more`);
    info(kleur.yellow("Dry run — nothing uploaded."));
    return;
  }

  const client = new Client(requireConfig());

  // Create the folder tree up front so notes can link to folder IDs.
  const folderIds = await createFolderTree(client, pending);
  success(`Ensured ${folderIds.size} folder(s) exist on server.`);

  // Upload notes with bounded concurrency. Using a simple pool so the
  // progress line doesn't thrash.
  const concurrency = Math.max(1, opts.concurrency ?? 4);
  let done = 0;
  let failed = 0;
  const errors: string[] = [];
  async function worker(queue: PendingNote[]) {
    while (queue.length > 0) {
      const note = queue.shift();
      if (!note) break;
      try {
        await client.createNote({
          title: note.front.title || undefined,
          body: note.body,
          folder_id: note.folder ? folderIds.get(note.folder) ?? null : null,
          tags: note.front.tags ?? [],
          pinned: !!note.front.pinned,
          // Preserved via the extended NoteCreate schema.
          created_at: note.front.created,
          updated_at: note.front.updated,
        } as Parameters<Client["createNote"]>[0]);
        done++;
      } catch (err) {
        failed++;
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`${note.filePath}: ${msg}`);
      }
      if ((done + failed) % 10 === 0) {
        process.stderr.write(
          kleur.gray(`\r  uploaded ${done}/${pending.length}${failed ? kleur.red(` (${failed} failed)`) : ""}`),
        );
      }
    }
  }

  const queue = [...pending];
  await Promise.all(Array.from({ length: concurrency }, () => worker(queue)));
  process.stderr.write("\n");

  if (failed > 0) {
    info(kleur.red(`${failed} upload(s) failed:`));
    for (const e of errors.slice(0, 10)) info(`  ${e}`);
    if (errors.length > 10) info(`  … ${errors.length - 10} more`);
  }
  success(`Imported ${done} notes${failed ? ` (${failed} failed)` : ""}`);
}

// ─── Directory walk ─────────────────────────────────────────────────────────

function collectNotes(root: string): PendingNote[] {
  const out: PendingNote[] = [];
  function walk(dir: string, folderPath: string) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.name.startsWith(".")) continue; // skip .notekeeper-dump.json etc.
      if (entry.isDirectory()) {
        // `_unfiled` at the root is a sentinel; its contents belong to no folder.
        if (folderPath === "" && entry.name === "_unfiled") {
          walk(full, "");
        } else {
          const nextFolder = folderPath ? `${folderPath}/${entry.name}` : entry.name;
          walk(full, nextFolder);
        }
        continue;
      }
      if (!entry.name.toLowerCase().endsWith(".md")) continue;
      const raw = fs.readFileSync(full, "utf8");
      const { front, body } = parseMarkdownFile(raw);
      // Fall back to filename as title if front matter didn't carry one.
      if (!front.title) front.title = path.basename(entry.name, ".md");
      // Repair dumps produced before the export-time coalesce was added —
      // Apple Notes attributed runs leave behind fragmented `# Foo / # bar`
      // stacks that should have been one heading.
      out.push({ filePath: full, front, body: coalesceHeadings(body, front.title), folder: folderPath });
    }
  }
  walk(root, "");
  return out;
}

function countFolders(notes: PendingNote[]): number {
  const s = new Set<string>();
  for (const n of notes) if (n.folder) s.add(n.folder);
  return s.size;
}

// ─── Server folder reconciliation ───────────────────────────────────────────

/** Create (or look up) every folder path present in the dump. Returns a map
 *  from `"Parent/Child"` → server folder_id. */
async function createFolderTree(
  client: Client,
  notes: PendingNote[],
): Promise<Map<string, string>> {
  const needed = new Set<string>();
  for (const n of notes) {
    if (!n.folder) continue;
    // Include every ancestor so parents are created before children.
    const parts = n.folder.split("/");
    for (let i = 1; i <= parts.length; i++) needed.add(parts.slice(0, i).join("/"));
  }

  const existing = await client.listFolders();
  const byParentAndName = new Map<string, string>(); // key = `${parent_id ?? ""}:${name}`
  for (const f of existing.folders) {
    byParentAndName.set(`${f.parent_id ?? ""}:${f.name}`, f.id);
  }

  const ids = new Map<string, string>();
  // Sort by depth so parents come first.
  const paths = [...needed].sort((a, b) => a.split("/").length - b.split("/").length);
  for (const p of paths) {
    const parts = p.split("/");
    const name = parts[parts.length - 1]!;
    const parentPath = parts.slice(0, -1).join("/");
    const parentId = parentPath ? ids.get(parentPath) ?? null : null;
    const key = `${parentId ?? ""}:${name}`;
    const existingId = byParentAndName.get(key);
    if (existingId) {
      ids.set(p, existingId);
      continue;
    }
    const created = await client.createFolder({ name, parent_id: parentId });
    ids.set(p, created.id);
    byParentAndName.set(key, created.id);
  }
  return ids;
}
