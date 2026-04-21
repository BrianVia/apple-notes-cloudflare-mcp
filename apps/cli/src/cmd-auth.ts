import { Command } from "commander";
import kleur from "kleur";
import { Client } from "./client";
import { saveConfig, clearConfig, loadConfig } from "./config";
import { die, success, info } from "./output";

export function registerAuthCommands(program: Command) {
  program
    .command("login")
    .description("Save credentials for a notekeeper endpoint")
    .requiredOption("--endpoint <url>", "API endpoint, e.g. https://notekeeper.you.workers.dev")
    .requiredOption("--key <api_key>", "API key (nk_live_...)")
    .action(async (opts: { endpoint: string; key: string }) => {
      if (!opts.key.startsWith("nk_live_")) {
        die("API key must start with nk_live_");
      }
      const client = new Client({ endpoint: opts.endpoint, api_key: opts.key });
      try {
        await client.verify();
      } catch (err) {
        die(`could not verify credentials: ${(err as Error).message}`);
      }
      saveConfig({ endpoint: opts.endpoint, api_key: opts.key });
      success(`Logged in to ${opts.endpoint}`);
      info("Config saved to ~/.config/notekeeper/config.json (mode 0600)");
    });

  program
    .command("logout")
    .description("Remove saved credentials")
    .action(() => {
      clearConfig();
      success("Logged out");
    });

  program
    .command("whoami")
    .description("Show current endpoint")
    .action(() => {
      const cfg = loadConfig();
      if (!cfg) die("not logged in");
      process.stdout.write(`${kleur.bold("endpoint")}: ${cfg.endpoint}\n`);
      process.stdout.write(`${kleur.bold("key")}:      ${cfg.api_key.slice(0, 12)}…\n`);
    });
}
