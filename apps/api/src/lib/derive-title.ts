/**
 * Pick a title from a note body's first non-empty line. Strips Markdown
 * decorations that would otherwise show up literally in list views —
 * heading markers, emphasis (`*`/`_`), strikethrough, inline code.
 *
 * Mirrored on the Swift side at AppModel.deriveTitle (apps/apple/...). Keep
 * the two in sync — drift here causes the local cache to disagree with the
 * server's flushed title and the UI to flicker between the two.
 */
export function deriveTitle(body: string): string {
  for (const line of body.split("\n")) {
    const cleaned = line
      .replace(/^#+\s*/, "")
      .replace(/[*_~`]/g, "")
      .trim();
    if (cleaned) return cleaned.slice(0, 200);
  }
  return "New Note";
}
