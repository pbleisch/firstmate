#!/usr/bin/env node
// Semantic policy for the history-surgery seatbelt: does a shell command run a
// git operation that rebuilds branch history or resolves conflicts by taking a
// side wholesale, from the PRIMARY firstmate shell?
//
// The supervisor never performs history surgery in a project: grafting a tree
// with commit-tree, reset --hard, and one-side conflict resolution are how a
// stale snapshot reverted merged work. Conflict resolution and branch
// rebuilding route to a worker instead. The environmental scoping to the real
// primary checkout lives in the bin/fm-cd-pretool-check.sh transport, not here.
// See docs/history-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification. Unlike the cd policy, this one also looks inside subshell and
// brace groups, command substitutions, and `sh -c` style payloads, because a
// git command runs wherever it is nested. It never evaluates, expands, sources,
// or runs any byte of the submitted command.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "history-surgery":
    "history surgery is never run from the firstmate supervisor shell: commit-tree, reset --hard, and taking one side of a conflict wholesale (checkout or restore --ours/--theirs, -X ours/theirs, -s ours) are how a stale tree reverts merged work. Route conflict resolution or branch rebuilding to a worker, whose instructions require merging a freshly fetched origin/<base> and resolving each conflict on its merits.",
};

const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh"]);
const MAX_DEPTH = 8;

// git global options that consume the following word.
const GIT_OPTIONS_WITH_ARGUMENT = new Set([
  "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--list-cmds",
]);

const MERGING = new Set(["merge", "rebase", "pull", "cherry-pick", "revert"]);
const SIDES = new Set(["ours", "theirs"]);

function basename(value) {
  return value.split("/").at(-1);
}

function gitSubcommand(words, start) {
  let index = start;
  while (index < words.length) {
    const value = words[index].value;
    if (GIT_OPTIONS_WITH_ARGUMENT.has(value)) {
      index += 2;
      continue;
    }
    if (value.startsWith("-")) {
      index += 1;
      continue;
    }
    return { name: value, args: words.slice(index + 1).map((word) => word.value) };
  }
  return null;
}

function takesSideWholesale(args) {
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "-X" || arg === "--strategy-option" || arg === "-s" || arg === "--strategy") {
      if (SIDES.has(args[i + 1])) return true;
      continue;
    }
    if (/^-X(ours|theirs)$/.test(arg) || /^-s(ours)$/.test(arg)) return true;
    if (/^--strategy-option=(ours|theirs)$/.test(arg) || /^--strategy=ours$/.test(arg)) return true;
  }
  return false;
}

function isSurgery(sub) {
  if (!sub) return false;
  const { name, args } = sub;
  if (name === "commit-tree") return true;
  if (name === "reset") return args.includes("--hard");
  if (name === "checkout" || name === "restore") return args.includes("--ours") || args.includes("--theirs");
  if (MERGING.has(name)) return takesSideWholesale(args);
  return false;
}

// Nested programs: groups, command substitutions, and `sh -c <payload>`.
function nestedPrograms(tokens, position) {
  const nested = [];
  for (const token of tokens) {
    if (token.type === "group") nested.push(token.content);
    if (token.type === "word") {
      for (const sub of token.subs || []) {
        if (sub.kind === "command" && typeof sub.content === "string") nested.push(sub.content);
      }
    }
  }
  if (position.command && SHELLS.has(basename(position.command.value))) {
    const args = position.words.slice(position.index + 1);
    for (let i = 0; i < args.length; i += 1) {
      const value = args[i].value;
      if (/^-[A-Za-z]*c[A-Za-z]*$/.test(value) && args[i + 1]) {
        nested.push(args[i + 1].value);
        break;
      }
      if (!value.startsWith("-")) break;
    }
  }
  nested.push(...(position.wrapperPayloads || []));
  return nested;
}

function inspect(command, depth) {
  if (depth > MAX_DEPTH) return false;
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize, as the cd policy does:
  // the threat model is a supervisor's mistake, not a deliberate bypass.
  if (lexed.error) return false;
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    const position = commandPosition(node);
    if (position.command && basename(position.command.value) === "git") {
      if (isSurgery(gitSubcommand(position.words, position.index + 1))) return true;
    }
    for (const program of nestedPrograms(node, position)) {
      if (inspect(program, depth + 1)) return true;
    }
  }
  return false;
}

function decision(command) {
  if (inspect(command, 0)) return { decision: "deny", code: "history-surgery", reason: REASONS["history-surgery"] };
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
