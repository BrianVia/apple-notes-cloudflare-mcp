import kleur from "kleur";

export interface OutputOptions {
  json?: boolean;
}

export function out(data: unknown, opts: OutputOptions = {}) {
  if (opts.json) {
    process.stdout.write(JSON.stringify(data, null, 2) + "\n");
  }
}

export function die(message: string, code = 1): never {
  process.stderr.write(kleur.red(`error: ${message}`) + "\n");
  process.exit(code);
}

export function info(message: string) {
  process.stderr.write(kleur.gray(message) + "\n");
}

export function success(message: string) {
  process.stderr.write(kleur.green(`✓ ${message}`) + "\n");
}

/** Relative time like "2m ago", "yesterday", "Mar 4". */
export function relTime(iso: string): string {
  const then = new Date(iso).getTime();
  const now = Date.now();
  const diff = Math.floor((now - then) / 1000);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 86400 * 7) return `${Math.floor(diff / 86400)}d ago`;
  const d = new Date(iso);
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return sameYear
    ? d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
    : d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

/** Print a simple table with auto-sized columns. */
export function table(rows: Record<string, string>[], columns: string[]) {
  if (rows.length === 0) {
    info("(none)");
    return;
  }
  const widths = columns.map((col) =>
    Math.max(col.length, ...rows.map((r) => (r[col] ?? "").length)),
  );
  const pad = (s: string, w: number) => s + " ".repeat(Math.max(0, w - s.length));

  const header = columns.map((col, i) => kleur.bold().gray(pad(col, widths[i]!))).join("  ");
  process.stdout.write(header + "\n");
  for (const r of rows) {
    process.stdout.write(columns.map((col, i) => pad(r[col] ?? "", widths[i]!)).join("  ") + "\n");
  }
}

export function truncate(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, Math.max(0, n - 1)) + "…";
}
