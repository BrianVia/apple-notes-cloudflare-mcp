#!/usr/bin/env bun
import { Command } from "commander";
import kleur from "kleur";
import { registerAppleNotesCommands } from "./cmd-apple-notes";
import { registerPushCommand } from "./cmd-push";

const program = new Command()
  .name("nk")
  .description("Export Apple Notes to a read-only mirror")
  .version("0.1.0");

registerAppleNotesCommands(program);
registerPushCommand(program);

try {
  await program.parseAsync(process.argv);
} catch (error) {
  process.stderr.write(kleur.red(`error: ${(error as Error).message}\n`));
  process.exit(1);
}
