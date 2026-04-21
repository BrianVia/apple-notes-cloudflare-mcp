import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export interface CliConfig {
  endpoint: string;
  api_key: string;
}

function configDir(): string {
  const xdg = process.env.XDG_CONFIG_HOME;
  return path.join(xdg || path.join(os.homedir(), ".config"), "notekeeper");
}

function configPath(): string {
  return path.join(configDir(), "config.json");
}

export function loadConfig(): CliConfig | null {
  const p = configPath();
  if (!fs.existsSync(p)) return null;
  try {
    const raw = fs.readFileSync(p, "utf8");
    return JSON.parse(raw) as CliConfig;
  } catch {
    return null;
  }
}

export function saveConfig(cfg: CliConfig): void {
  const dir = configDir();
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const p = configPath();
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2), { mode: 0o600 });
}

export function requireConfig(): CliConfig {
  const cfg = loadConfig();
  if (!cfg) {
    console.error("Not logged in. Run: nk login --endpoint <url> --key <api_key>");
    process.exit(1);
  }
  return cfg;
}

export function clearConfig(): void {
  const p = configPath();
  if (fs.existsSync(p)) fs.unlinkSync(p);
}
