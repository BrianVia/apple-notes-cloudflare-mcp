import { Command } from "commander";
import kleur from "kleur";
import { Client } from "./client";
import { requireConfig } from "./config";
import { die, info, out, relTime, success, table, truncate } from "./output";

export function registerFolderCommands(program: Command) {
  const folders = program.command("folders").description("Manage folders");

  folders
    .command("ls")
    .description("List folders")
    .option("--json", "Output JSON")
    .action(async (opts) => {
      const client = new Client(requireConfig());
      const res = await client.listFolders();
      if (opts.json) return out(res, { json: true });
      if (res.folders.length === 0) return info("(no folders)");
      // Build a tree and render indented.
      const byParent = new Map<string | null, typeof res.folders>();
      for (const f of res.folders) {
        const arr = byParent.get(f.parent_id) ?? [];
        arr.push(f);
        byParent.set(f.parent_id, arr);
      }
      const render = (parent: string | null, depth: number) => {
        for (const f of byParent.get(parent) ?? []) {
          process.stdout.write(
            `${"  ".repeat(depth)}${kleur.gray(f.id.slice(0, 8))}  ${kleur.bold(f.name)}\n`,
          );
          render(f.id, depth + 1);
        }
      };
      render(null, 0);
    });

  folders
    .command("new <name>")
    .description("Create a folder")
    .option("--parent <id>", "Parent folder id")
    .action(async (name: string, opts) => {
      const client = new Client(requireConfig());
      const f = await client.createFolder({ name, parent_id: opts.parent ?? null });
      success(`Created folder ${kleur.cyan(f.id.slice(0, 8))} — ${kleur.bold(f.name)}`);
    });

  folders
    .command("rm <id>")
    .description("Delete a folder (notes inside are un-foldered, not deleted)")
    .action(async (id: string) => {
      const client = new Client(requireConfig());
      await client.deleteFolder(id);
      success("Deleted");
    });
}

export function registerTagCommands(program: Command) {
  program
    .command("tags")
    .description("List all tags with counts")
    .option("--json", "Output JSON")
    .action(async (opts) => {
      const client = new Client(requireConfig());
      const res = await client.listTags();
      if (opts.json) return out(res, { json: true });
      if (res.tags.length === 0) return info("(no tags)");
      table(
        res.tags.map((t) => ({ tag: t.name, count: String(t.count) })),
        ["tag", "count"],
      );
    });
}

export function registerSearchCommand(program: Command) {
  program
    .command("search <query...>")
    .description("Full-text search across notes")
    .option("-n, --limit <n>", "Max results", "25")
    .option("--json", "Output JSON")
    .action(async (queryParts: string[], opts) => {
      const client = new Client(requireConfig());
      const q = queryParts.join(" ");
      const res = await client.search(q, Number(opts.limit));
      if (opts.json) return out(res, { json: true });
      if (res.results.length === 0) return info(`No matches for ${kleur.bold(q)}`);
      for (const r of res.results) {
        process.stdout.write(
          `${kleur.cyan(r.id.slice(0, 8))}  ${kleur.bold(truncate(r.title, 60))}  ${kleur.gray(relTime(r.updated_at))}\n`,
        );
        // Strip the <mark> HTML tags and colorize in terminal instead.
        const snippet = r.snippet
          .replaceAll("<mark>", "\x1b[33m")
          .replaceAll("</mark>", "\x1b[0m");
        process.stdout.write(`  ${snippet}\n\n`);
      }
    });
}

export function registerKeyCommands(program: Command) {
  const keys = program.command("keys").description("Manage API keys");

  keys
    .command("ls")
    .description("List API keys")
    .option("--json", "Output JSON")
    .action(async (opts) => {
      const client = new Client(requireConfig());
      const res = await client.listKeys();
      if (opts.json) return out(res, { json: true });
      if (res.keys.length === 0) return info("(no keys)");
      table(
        res.keys.map((k) => ({
          id: k.id.slice(0, 8),
          name: k.name,
          prefix: k.prefix + "…",
          scopes: k.scopes.join(","),
          "last used": k.last_used_at ? relTime(k.last_used_at) : kleur.gray("never"),
          expires: k.expires_at ? relTime(k.expires_at) : kleur.gray("never"),
        })),
        ["id", "name", "prefix", "scopes", "last used", "expires"],
      );
    });

  keys
    .command("new <name>")
    .description("Create an API key (secret returned once — save it now)")
    .option("--scope <s>", "Scope (read|write|admin, repeatable)", collect, [] as string[])
    .option("--expires-in <days>", "Expiry in days")
    .action(async (name: string, opts) => {
      if (opts.scope.length === 0) die("at least one --scope is required");
      const client = new Client(requireConfig());
      const key = await client.createKey({
        name,
        scopes: opts.scope,
        expires_in_days: opts.expiresIn ? Number(opts.expiresIn) : undefined,
      });
      process.stdout.write("\n");
      process.stdout.write(kleur.yellow().bold("⚠  Save this key now — it will not be shown again.\n\n"));
      process.stdout.write(`${kleur.bold("name")}:    ${key.name}\n`);
      process.stdout.write(`${kleur.bold("id")}:      ${key.id}\n`);
      process.stdout.write(`${kleur.bold("scopes")}:  ${key.scopes.join(", ")}\n`);
      process.stdout.write(`${kleur.bold("secret")}:  ${kleur.cyan(key.secret)}\n\n`);
    });

  keys
    .command("rm <id>")
    .description("Revoke an API key")
    .action(async (id: string) => {
      const client = new Client(requireConfig());
      await client.revokeKey(id);
      success("Revoked");
    });
}

function collect<T>(value: T, previous: T[]): T[] {
  return [...previous, value];
}
