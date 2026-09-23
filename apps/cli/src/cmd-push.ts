import type { Command } from "commander";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { exportAppleNotes, parseMarkdownFile } from "./cmd-apple-notes";
import { info, success } from "./output";

// Last-pushed payload hash + timestamp; lets frequent cron runs skip the
// upload entirely when nothing changed. Re-pushes anyway after 24h so the
// mirror self-heals if the remote side ever loses data.
const STATE_FILE = path.join(os.homedir(), ".config", "nk", "last-push.json");
const MAX_SKIP_MS = 24 * 60 * 60 * 1000;

function markdownFiles(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    return entry.isDirectory() ? markdownFiles(file) : entry.isFile() && entry.name.endsWith(".md") ? [file] : [];
  });
}

export function registerPushCommand(program: Command) {
  program
    .command("push")
    .description("Export Apple Notes and replace the remote mirror")
    .option("--api-url <url>", "Worker URL (overrides NK_API_URL)")
    .option("--token <token>", "API token (overrides NK_API_TOKEN)")
    .action(async (opts: { apiUrl?: string; token?: string }) => {
      const apiUrl = opts.apiUrl ?? process.env.NK_API_URL;
      const token = opts.token ?? process.env.NK_API_TOKEN;
      if (!apiUrl) throw new Error("set NK_API_URL or pass --api-url");
      if (!token) throw new Error("set NK_API_TOKEN or pass --token");

      const dumpDir = fs.mkdtempSync(path.join(os.tmpdir(), "apple-notes-cloudflare-mcp-"));
      const cleanup = () => fs.rmSync(dumpDir, { recursive: true, force: true });
      process.once("exit", cleanup);
      try {
        await exportAppleNotes(dumpDir);
        const notes = markdownFiles(dumpDir).map((file) => {
          const markdown = fs.readFileSync(file, "utf8");
          const { front } = parseMarkdownFile(markdown);
          const relativeDir = path.relative(dumpDir, path.dirname(file));
          const folder = relativeDir === "." || relativeDir === "_unfiled"
            ? ""
            : relativeDir.split(path.sep).join("/");
          return {
            folder,
            title: front.title,
            created: front.created,
            updated: front.updated,
            pinned: front.pinned ?? false,
            markdown,
          };
        });

        const body = JSON.stringify(notes);
        const hash = crypto.createHash("sha256").update(body).digest("hex");
        try {
          const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
          if (state.hash === hash && Date.now() - state.pushedAt < MAX_SKIP_MS) {
            info("No changes since last push; skipping upload.");
            return;
          }
        } catch { /* no/bad state file → push */ }

        const response = await fetch(`${apiUrl.replace(/\/+$/, "")}/notes`, {
          method: "PUT",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body,
        });
        if (!response.ok) {
          throw new Error(`push failed (${response.status}): ${await response.text()}`);
        }
        const result = await response.json() as { count: number; skipped?: unknown[] };
        fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
        fs.writeFileSync(STATE_FILE, JSON.stringify({ hash, pushedAt: Date.now() }));
        success(`Pushed ${result.count} notes${result.skipped?.length ? `; skipped ${result.skipped.length}` : ""}.`);
      } finally {
        process.off("exit", cleanup);
        cleanup();
      }
    });
}
