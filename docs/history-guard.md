# History-surgery PreToolUse seatbelt

This document is the authoritative human-readable contract for the history-surgery seatbelt.
`bin/fm-history-command-policy.mjs` is the single decision owner.
`bin/fm-cd-pretool-check.sh` is its harness transport, primary-checkout scope, and output renderer, shared with the cd-guard (`docs/cd-guard.md`).

## Purpose and boundary

The supervisor never performs history surgery in a project.
Grafting a tree with `git commit-tree`, `git reset --hard`, and resolving conflicts by taking one side wholesale are how a stale snapshot can be presented as a fresh commit on the current base and merged as a silent revert.
Conflict resolution and branch rebuilding route to a worker, whose ship instructions (`bin/fm-dod-lib.sh`) require merging a freshly fetched `origin/<base>` and resolving each conflict on its merits.
The seatbelt denies those git operations when the primary firstmate shell runs them.

Like the cd-guard, it classifies shell command positions only and never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is a supervisor's mistake, not a deliberately obfuscated bypass.
Scripted rewriting of conflict markers cannot be recognized from a command line, so it remains a contract rule in `AGENTS.md` rather than a seatbelt case.

## Scope

The seatbelt shares the cd-guard's scope: it fires only in a plain firstmate checkout where git-dir equals git-common-dir, and is inert in a worker's linked worktree, where conflict resolution belongs.
It applies to the firstmate home's own repository too, because that home is maintained through guarded scripts, never by hand-typed history rewrites.

## Block vs allow

The policy denies a `git` invocation, after skipping git's global options such as `-C <dir>` and `-c <key=value>`, whose subcommand is:

- `commit-tree`;
- `reset` with `--hard`;
- `checkout` or `restore` with `--ours` or `--theirs`;
- `merge`, `rebase`, `pull`, `cherry-pick`, or `revert` with `-X ours`, `-X theirs`, `--strategy-option=ours|theirs`, `-s ours`, or `--strategy=ours`.

It looks for those invocations at every executed position, including inside subshell and brace groups, command substitutions, wrapper payloads, and `sh -c` style payloads, because a git command takes effect wherever it is nested.
Everything else is allowed, including `reset --soft`, an ordinary `merge`, and the same words appearing as quoted data.
Untokenizable syntax fails open, as in the cd-guard.

## Stable reason code

| Code | Meaning |
| --- | --- |
| `history-surgery` | A git operation that rebuilds history or takes one side of a conflict wholesale would run from the primary firstmate shell. |

## Transport

`bin/fm-cd-pretool-check.sh` runs this policy when its prefilter sees a `git` word together with `commit-tree`, `reset`, `ours`, or `theirs`, and runs the cd policy on its own prefilter; the first deny wins.
The deny output, exit codes, and per-harness rendering are exactly the cd-guard's, so every harness adapter `docs/cd-guard.md` lists carries this seatbelt without a new registration, and that document's live validation of the transport applies unchanged.

## Automated validation

`tests/fm-cd-pretool-check.test.sh` owns the history acceptance matrix, run through the same five harness entry forms as the cd matrix, plus the linked-worktree inert case and the policy CLI contract.
