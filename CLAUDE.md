# CLAUDE.md

## Git workflow

- **Never create a branch or a pull request without an explicit request.** When asked to commit,
  commit to the branch currently checked out, including `main`.
- Commit only when asked. Push only when asked. Each is a separate ask.

## Comments

**10–25% comment-to-code, and closer to 10 than 25.** A comment records a non-obvious external
fact — what an upstream CLI actually does, what a bash version actually does — in one or two lines.
It never narrates what the code says, never explains why a past version was wrong, and never
recounts the incident that led to the current shape. That belongs in the commit message. Prune
whatever you add before you finish; the same discipline applies to README.md.

## Bash only

No Python, no `jq`, no added runtime — in the repo and in anything you run while working on
it, including one-off commands at the terminal. Bash, coreutils, `awk`, `sed`, and the two
upstream npm CLIs through `npx`.

## Write for bash 3.2 and a BSD userland

macOS is a supported host, so a GNU-only flag is a bug even when it works here: no `find -printf`,
`grep -P`, `grep -U` or bare `sed -i`; `-ef` for symlink identity; name stdin where BSD needs it
(`paste -sd, -`). Under `set -u`, bash 3.2 calls `"${a[@]}"` unbound when `a` is empty — build
strings, or expand as `${a[@]+"${a[@]}"}`. `awk` needs POSIX character classes; `sync.sh` proves it
at preflight. Run the suite under `bash:3.2` with a busybox userland before calling a change
portable.

## Both entry points, one script

`sync.sh` runs from a checkout and streamed through `curl | bash`. Piped, `BASH_SOURCE` is empty
and the manifests are not on disk yet: never read `${BASH_SOURCE[0]}` without a `:-` fallback, and
reach the repo through `$REPO_DIR`. Keep the header comment contiguous from line 2 — `--help`
prints it.

## The manifests are the argument

A row in `manifests/` is the only place a skill, server or plugin is named. Nothing passes a name
on a command line: `codex mcp add copilotkit …` was run three times with three different URLs, and
Codex kept only the last under a name that described none of them.

## Identity is the target, never the name

A server is satisfied only when the agent resolves the declared name to the declared target. Do not
compare transport labels — the same SSE endpoint is `sse`, `remote` and `streamable_http` to the
three agents. For stdio the target is the package, not the invocation: `npx` was already stripped on
that reasoning, and the install directory and resolved version are the same noise. Do not extend
that to a row pinning a version. A URL is compared whole.

A mirrored skill is the same problem: a link to the wrong skill resolves and has a `SKILL.md`, so
compare with `-ef` against its own payload. When adding a check, ask what it would accept that is
wrong, not just what it would reject.

## Verify what the agent reads, never what this repo wrote

A receipt proves the script ran, not that the host converged. Every check in `lib/verify.sh` reads
the agent's own artifact. When adding one, read the agent's binary to find where it looks.

## A dry run's job is the part it would *not* fix

Verification reads the host, and under `--dry-run` nothing has been applied, so a literal reading
repeats the whole plan back under ✗. Each pass records what it would do; verification subtracts it.
When adding a pass, record its plan; when adding a check, filter it. Report per kind, not per name.
Only under `--dry-run` — a real run must read the result.

## Let upstream own upstream's state

`~/.agents/.skill-lock.json` belongs to `skills`. Read it; never write it. It is also the
provenance oracle: an entry it lacks was written by hand, so prune's set is the lock minus the
manifest. Do not widen that to the filesystem — a store directory nobody fetched is somebody's own
work, and there is no upper bound on how many of those a person has.

## Convergence is not the same as reinstalling

A pass applies the difference. `skills add` re-copies everything it is handed, which turned every
run into a full re-download reporting no change — destroying the one signal that matters.

## Never uninstall somebody's decision

MCP servers and plugins are reported and left; Codex's `node_repl` is injected by the ChatGPT
desktop app. `--prune-duplicate-mcp` is the one exception, because a second name for a declared
endpoint provides nothing of its own. Before wiring any upstream removal, read how it matches:
`add-mcp remove` takes a substring of the server name and `-y` accepts every match.

## Close every child command's stdin

`npx` reads stdin, which drains the enclosing `while read` loop — or, piped from curl, the script
bash has not finished reading. `run()` does this; keep new external calls going through it, and
give the bootstrap's own commands their own `< /dev/null`.
