# CLAUDE.md

## Git workflow

- **Never create a branch or a pull request without an explicit request.** When asked to commit,
  commit to the branch that is currently checked out — including `main`. Do not branch first as a
  precaution, and do not offer branching as a safer default.
- Commit only when asked. Push only when asked. Each is a separate ask; permission to commit is not
  permission to push.

## Bash only

No Python, no `jq`, no added runtime. Bash, coreutils, `awk`, `sed`, and the two upstream npm CLIs
through `npx`. A dependency this repo does not have is a dependency it never has to keep in step
with, and every agent config here is a format `awk` reads without help.

## Write for bash 3.2 and a BSD userland

macOS ships bash 3.2 and BSD tools, and it is a supported host, so a GNU-only flag is a bug even
when it works here. No `find -printf`, no `grep -P`, no `grep -U`, no bare `sed -i`, no `readlink
-f` — use `-ef` for symlink identity. Name stdin explicitly where BSD needs it (`paste -sd, -`).

The trap that does not announce itself: under `set -u`, bash 3.2 calls `"${a[@]}"` unbound when
`a` is empty. Prefer a string built as you go; where an array is genuinely right, expand it as
`${a[@]+"${a[@]}"}`. In a command substitution this fails quietly — the subshell dies, the value
comes back empty, and on a converged host empty is the correct answer, so the only symptom is
stderr noise nobody reads.

`awk` needs POSIX character classes for `[[:space:]]` to mean what it says; the preflight in
`sync.sh` proves that rather than assuming it. Run `bash tests/run.sh` under `bash:3.2` with a
busybox userland before calling a change portable.

## Both entry points, one script

`sync.sh` is run from a checkout and streamed through `curl | bash`. Piped, `BASH_SOURCE` is empty
and the manifests are not on disk yet, so nothing may read `${BASH_SOURCE[0]}` without a `:-`
fallback, and anything reading the repo must go through `$REPO_DIR` — which the bootstrap sets to
the unpacked payload. Keep the header comment block contiguous from line 2: `--help` prints it.

## The manifests are the argument

A row in `manifests/` is the only place a skill, server or plugin is named. Nothing may pass a
name on a command line: `codex mcp add copilotkit …` was run three times with three different
URLs, and Codex kept only the last one under a name that described none of them.

## Identity is the target, never the name

A server is satisfied only when the agent resolves the declared name to the declared target. A
name-only check reports the collision above as converged, which it did for a whole day. Do not
compare transport labels — the same SSE endpoint is `sse` to Claude Code, `remote` to OpenCode and
`streamable_http` to Codex. Compare remote-versus-stdio and the URL.

For stdio the target is the package, not the invocation. `npx` was already stripped on that
reasoning; the install directory and the resolved version are the same kind of noise, so a global
binary satisfies a row naming its package. Do not extend that to a row pinning a version — writing
one is the only way to say the version matters. A URL is compared whole: every character of it is
the address.

A mirrored skill is the same problem wearing a different hat: a link to the wrong skill resolves
and has a `SKILL.md`, so an existence check passes while the agent loads something else under that
name. Compare with `-ef` against the skill's own payload in the store. Whenever a new check is
added here, ask what it would accept that is wrong, not just what it would reject.

## Verify what the agent reads, never what this repo wrote

A receipt proves the script ran. It does not prove the host converged. Every check in
`lib/verify.sh` reads the agent's own artifact — the store on disk, the link in the agent's skills
directory, the server entry in the agent's config file. When adding a check, read the agent's
binary to find out where it actually looks; the three agents disagree, and OpenCode reads the
shared store directly while Claude Code and Codex do not.

## Let upstream own upstream's state

`~/.agents/.skill-lock.json` belongs to `skills`. Read it; never write it. When a repair seems to
need lock surgery, the cause is usually a bug on this side — the orphaned entries that looked like
a lock problem were a comma-joined `--skill` and an `npx` that swallowed the loop's stdin.

## Convergence is not the same as reinstalling

A pass compares the manifest against the live configuration and applies the difference. Running the
underlying CLI unconditionally would work, but `skills add` re-copies everything it is handed, so
that turned every run into a full re-download that reported no change — destroying the one signal
that matters: a settled host prints no deltas.

## Never uninstall somebody's decision

The manifest is authoritative over what a source installed, and nothing else. The lock says which
is which — `skills add` records a source and a sourceUrl per entry, so one it has never heard of
was written by hand — and prune's set is the lock minus the manifest. Do not widen it to the
filesystem: a store directory nobody fetched is somebody's own work, there is no upper bound on
how many of those a person has, and asking them to list each one here would be asking every
machine to declare what only one of them has. Read provenance off the host.

MCP servers and plugins are reported and left: Codex's `node_repl` is injected by the ChatGPT
desktop app, and removing it breaks the in-app browser. `--prune-duplicate-mcp` is the one
exception, and only because a second name for a declared endpoint provides nothing of its own.
Before wiring any upstream removal, read how it matches: `add-mcp remove` takes a substring of the
server name and `-y` accepts every match, so it will happily take a declared server along with the
one you asked for.

## A dry run's job is the part it would *not* fix

Verification reads the host, and under `--dry-run` nothing has been applied, so a literal reading
repeats the whole plan back under ✗ — an unconfigured machine reported 131 failures and exited
non-zero. Each pass records what it would do; verification subtracts it. When adding a pass, record
its plan; when adding a check, filter it. Report per kind, not per name.

Only under `--dry-run`. On a real run the work has happened and verification must read the result,
never the ledger — trusting the ledger would make it a receipt, which is the thing this repo does
not do.

## Close every child command's stdin

Most run inside `while read` loops and `npx` reads stdin, so an open descriptor lets the first
iteration swallow the rest of the loop's input. Streamed through `curl | bash` the stakes are
higher: stdin is then the script bash has not finished reading, and a child that drains it takes
the rest of the run with it. `run()` in `lib/log.sh` does this for everything; keep new external
calls going through it, and give the bootstrap's own commands — which run before `run()` exists —
their own `< /dev/null`.

## Comments

Match the density of the code you are editing. State the non-obvious fact and stop; do not restate
what the code says.
