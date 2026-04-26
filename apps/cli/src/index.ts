#!/usr/bin/env bun
import { Command } from "commander";
import kleur from "kleur";
import { registerAuthCommands } from "./cmd-auth";
import { registerNoteCommands } from "./cmd-notes";
import {
  registerFolderCommands,
  registerTagCommands,
  registerSearchCommand,
  registerKeyCommands,
} from "./cmd-misc";
import { registerAppleNotesCommands } from "./cmd-apple-notes";
import { registerImportCommands } from "./cmd-import";
import { ApiError } from "./client";

const program = new Command();

program
  .name("nk")
  .description("notekeeper — an Apple Notes-shaped CLI")
  .version("0.1.0");

registerAuthCommands(program);
registerNoteCommands(program);
registerFolderCommands(program);
registerTagCommands(program);
registerSearchCommand(program);
registerKeyCommands(program);
registerAppleNotesCommands(program);
registerImportCommands(program);

// Global error handler — commander won't catch async rejections from actions.
async function main() {
  try {
    await program.parseAsync(process.argv);
  } catch (err) {
    if (err instanceof ApiError) {
      process.stderr.write(
        kleur.red(`error (${err.status} ${err.code}): ${err.message}\n`),
      );
      if (err.details) {
        process.stderr.write(kleur.gray(JSON.stringify(err.details, null, 2) + "\n"));
      }
    } else {
      process.stderr.write(kleur.red(`error: ${(err as Error).message}\n`));
    }
    process.exit(1);
  }
}

main();
