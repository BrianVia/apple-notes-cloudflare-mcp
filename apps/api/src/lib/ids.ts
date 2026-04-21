import { customAlphabet } from "nanoid";

// 24 chars, lowercase alphanumeric. Enough entropy (~124 bits) without
// punctuation that trips up URLs/shells.
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
const nano = customAlphabet(alphabet, 24);

export function newId(): string {
  return nano();
}

// Validate without pulling zod — hot path.
export function isValidId(s: unknown): s is string {
  return typeof s === "string" && /^[a-z0-9]{24}$/.test(s);
}
