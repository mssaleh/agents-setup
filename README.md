# agents-setup

One manifest per concern, one idempotent script, three coding agents that agree.

Claude Code, Codex and OpenCode each want their skills, MCP servers and plugins configured in a
different place and a different format. Configuring them one at a time produces silent drift:
servers that exist in one agent and not another, servers overwritten by a name collision, skills
that resolve in one agent and dangle in the next. This repo makes the manifests authoritative and
converges every agent onto them.

## Quick start

```bash
# One-shot:
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash

# Report what would change first:
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash -s -- --dry-run

# On a Linux host that has wget but not curl:
wget -qO- https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash

# Or clone and run:
git clone https://github.com/mssaleh/agents-setup.git
cd agents-setup
./sync.sh
```

Piped in, the script downloads the manifests into a temporary directory, converges the host and
deletes them again. Nothing on the machine points back at this repository; what is left is
ordinary agent configuration under `$HOME`. Every flag works after `bash -s --`, and
`REPO_ARCHIVE_URL` points the payload somewhere else — a `file://` archive needs neither network
nor download tool.

Re-running is safe and is the point: a converged host prints no deltas, writes nothing, and
finishes in a few seconds.

## What it manages

| Layer | Manifest | Installer | Agents |
|---|---|---|---|
| Skills | `manifests/skills.tsv` | `npx skills` | Claude Code, Codex, OpenCode |
| MCP servers | `manifests/mcp.tsv` | `npx add-mcp` | Claude Code, Codex, OpenCode |
| Plugins | `manifests/plugins.tsv` | `claude plugin` | Claude Code |

Copilot CLI is not a target. It has a config directory but no binary on this host; add it to the
agents column of a row once the CLI is installed.

## Where each agent actually looks

Taken from the shipped binaries, not from documentation. This is what decides which agents need a
mirror:

| Agent | Skills | MCP servers |
|---|---|---|
| Claude Code | `~/.claude/skills/<name>/` | `~/.claude.json` → `mcpServers` |
| Codex | `$CODEX_HOME/skills/<name>/` | `~/.codex/config.toml` → `[mcp_servers.*]` |
| OpenCode | `~/.agents/skills/<name>/SKILL.md`, `~/.claude/skills/`, `~/.config/opencode/skill(s)/` | `~/.config/opencode/opencode.jsonc` → `mcp` |

**OpenCode reads the shared store directly**, so it is never mirrored into. Claude Code and Codex
read only their own directories, so the store is symlinked into both.

## How a run proceeds

The manifests are validated first — field counts, known modes and transports, known agent
names, no duplicated skill or server, no CRLF. Nothing runs against a manifest that cannot
mean what it says: a duplicated row installs twice and verifies twice, and a row whose mode
is `select\r` is only rejected on the day a skill from it goes missing.

1. **install** — for each source row, `skills add … -a universal` for the declared skills that are
   not in the store. Nothing else is requested.
2. **prune** — `skills remove` what the lock records and no row declares. A store entry the lock
   never fetched was written by hand and is out of scope.
3. **refresh** — `--update` only: `skills update -g -y`, upstream's own update over the lock, which
   prune has already reduced to exactly the manifest.
4. **mirror** — make `~/.claude/skills` and `$CODEX_HOME/skills` match the store: link everything
   the store holds, drop links to what it no longer holds, and replace a full copy that shadows a
   managed skill. The two halves split the names between them and neither touches the other's, so
   nothing is linked and unlinked in the same run. Local directories are left alone — Codex ships
   its own `skills/.system/`.
5. **mcp** — install each row into the agents that lack it *or point somewhere else*.
6. **plugins** — register the marketplace and install the allowlist; report anything else.
7. **verify** — read every agent's own artifact back and exit non-zero if the manifest is unmet.

### A dry run reports what it would *not* fix

The passes above apply nothing under `--dry-run`, so verification necessarily reads the host as it
stands — and reading it literally means repeating the entire plan back under ✗. An unconfigured
machine reported a hundred and thirty-one failures and exited non-zero when nothing was wrong with
it beyond never having been set up, and the three findings that did need a decision were somewhere
in the middle of that.

So each pass records what it would do, and verification subtracts it. What survives is the part no
pass acts on: a stray file in the store, a skill symlinked out to a working copy, a project-scoped
server, a plugin nobody declared. A dry run whose plan covers everything says so and exits zero.

The ledger is consulted under `--dry-run` alone. On a real run the work has actually happened, and
verification has to read the result rather than trust that the command it invoked did what it said.

Findings are reported one line per kind, not one per name. Thirty-two missing skills are one line
naming thirty-two skills, then the same names again for each agent that mirrors them was the
difference between a report and a wall.

### Identity is the target, never the name

A row is satisfied only when the agent resolves the name to the declared target. This is the whole
reason the repo exists: `mcp add copilotkit …` run three times with three different URLs leaves one
server holding a name that describes none of them, and a name-only check calls that converged.

The same applies to a mirrored skill. A link left pointing at a different skill still resolves and
still has a `SKILL.md`, so "does it resolve?" passes while the agent loads the wrong skill under
that name; a local copy shadowing a managed skill passes for the same reason. Each mirrored skill
is checked with `-ef` against its own payload in the store.

A server that is present at the right URL but carries `enabled = false` is not satisfied
either: it is configured and it does not run.

The same collision arrives from the other direction as an undeclared server whose target a
manifest row already installs — `copilotkit-mcp` beside `copilotkit`, both on the same SSE
endpoint. Nothing is overwritten and nothing needs repairing; the agent simply opens the endpoint
twice and offers every tool on it twice. It is called out by name rather than listed with the
other undeclared servers, and `--prune-duplicate-mcp` removes it. Only a server whose target a
declared row already installs is ever a candidate, so nothing that provides something of its own
can be caught by it.

That flag declines one case rather than risking it. `add-mcp remove <query>` matches
`serverName.includes(query)` and `-y` accepts every match, so removing `doc` would take a declared
`docs` with it; a name that is a substring of another configured one is reported for you to remove
by hand. The pass also runs before the converge pass, so anything caught anyway comes back in the
same run.

Transport *labels* are not compared, because the agents disagree about them — the same SSE endpoint
is `sse` to Claude Code, `remote` to OpenCode, and reported as `streamable_http` by Codex. What is
compared is remote-versus-stdio and the URL or package itself, which every agent agrees on.

For a stdio row the identity is the **package**, not the way it is started. The `npx` runner is
stripped, and so are the directory a binary was installed into and the version it resolved at:
`npx -y next-devtools-mcp@latest` and `~/.npm/packages/bin/next-devtools-mcp` are one server begun
two ways, and rewriting a host that already works into the other form is churn — measured here,
npx costs 0.2–0.6 s per launch over the installed binary and buys nothing the manifest asked for.
A host that lacks the server still gets it installed exactly as the row is written.

A row that pins a version is the exception, because pinning is the only reason to write one:
`pkg@1.2.3` accepts nothing but `pkg@1.2.3`, while `pkg@latest` accepts any invocation of `pkg`.

### What the CLIs require

Three properties of the upstream tools shape the code, and each fails quietly rather than loudly:

- **`skills add` writes the store only when a universal agent is a target.** An agent is universal
  when its `skillsDir` is `.agents/skills`; `codex` and `opencode` are classified that way and
  `claude-code` is not. So `-a codex` writes the store and never `~/.codex/skills` — the only place
  the Codex binary looks — while `-a claude-code` alone writes a full copy into `~/.claude/skills`
  that shadows the store. `universal` is the id whose sole purpose is the store and which is never
  auto-detected, so naming it says "the store, and nothing else".
- **`-s` and `-a` are repeatable, not comma-separated.** `--skill a,b` is read as one skill named
  `a,b`, matches nothing, and still exits successfully. `add-mcp` rejects a joined `-a` list as
  "Invalid agents".
- **`skills add` re-downloads and re-copies whatever it is given**, whether or not the store already
  holds it. Asking for everything on every run rewrote all 35 payloads and reported no change, so
  only missing names are requested and refreshing is the separate `--update`.

Every child command runs with stdin closed. Most execute inside `while read` loops, and `npx`
reads stdin, so an open descriptor lets the first iteration swallow the rest of the loop's input.
The same descriptor is what makes the one-liner safe: piped in, the script bash is still reading
*is* stdin, and a child that drains it takes the rest of the run with it.

## The manifests

`manifests/skills.tsv` — `source`, `skills`, `mode`.

The `skills` column is authoritative over what a source installed, and lists names as they appear
in the store. A name is the
`name:` in the skill's own `SKILL.md`, which is what `--skill` matches; it is not always the repo's
directory name (`skills/react-best-practices/` installs as `vercel-react-best-practices`). Take
names from `npx skills add <source> -l`. `mode` is `select` when the repo carries more than you
want, `whole` when the source spec already names exactly one skill.

### A skill you wrote needs no row

The manifest is authoritative over what a source installed, and over nothing else. The lock draws
the line: `skills add` records a `source`, a `sourceUrl` and a `skillPath` for everything it
fetches, so an entry it has never heard of was written here by hand. Prune's set is exactly *what
the lock records, minus what the manifest declares* — which covers a payload nobody wants any more
and a bookkeeping entry whose payload went years ago, and leaves everything else alone.

So a skill of your own sits in the store, gets mirrored into all three agents like any other, is
reported once a run as `not installed from a source, left alone`, and is never anybody's to
delete. You do not list it here, and there is no limit on how many you have — they are yours, they
differ per machine, and the host already knows which is which.

Being wrong in that direction is the point: a lock reset or a pre-lock install makes a managed
skill look hand-written, and the cost is a stale directory nobody pruned rather than work nobody
can get back.

`manifests/mcp.tsv` — `name`, `transport`, `target`, `agents`.

The name is set here, never on a command line. Every row installs at user scope: `claude mcp add`
defaults to *project* scope, which is how a server ends up working in one directory and invisible
everywhere else.

`manifests/plugins.tsv` — `agent`, `marketplace`, `marketplace_source`, `plugin`.

The marketplace name is declared by the marketplace repo and need not match the basename of its
source, so both are recorded. The list is short by intent: a plugin ships commands, agents, hooks
and an MCP server as one unit, so it earns a row only when a skill plus an MCP row cannot express
the same capability.

### Adding something

```bash
npx skills find <query>              # or: npx add-mcp find <keyword>
$EDITOR manifests/skills.tsv         # add the row
./sync.sh --dry-run && ./sync.sh
```

## What it will not do

- **Uninstall a plugin.** An installed plugin no row declares is reported and left. Removing
  somebody's deliberate install is not convergence.
- **Remove an undeclared MCP server.** Codex's `node_repl` is injected by the ChatGPT desktop app;
  removing it breaks the in-app browser. The one exception is opt-in: `--prune-duplicate-mcp`
  clears a second name for an endpoint a declared row already installs, which by definition
  provides nothing of its own.
- **Rewrite a project-scoped Claude server.** It is reported, with the directory it is trapped in,
  so you can decide whether it should become a manifest row.
- **Edit the skill lock.** That file belongs to `skills`; it is read, and every write to it is left
  to `skills add` and `skills remove`.
- **Delete an orphaned plugin cache.** An abandoned `claude plugin install` leaves the full clone
  behind. The sizes are reported; `--prune-plugin-cache` opts in to removing them.

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Report every change without writing |
| `--only skills\|mcp\|plugins\|verify` | Run one pass |
| `--update` | Also pull upstream changes into installed skills |
| `--prune-plugin-cache` | Also delete marketplace clones with no registered marketplace |
| `--prune-duplicate-mcp` | Also remove an undeclared server whose target a declared row installs |

| Variable | Default | Purpose |
|---|---|---|
| `AGENTS_HOME` | `~/.agents` | Shared skill store root |
| `AGENTS_LOCK` | `$XDG_STATE_HOME/skills/` or `~/.agents/` | Skill lock, following upstream's own rule |
| `CLAUDE_HOME` | `$CLAUDE_CONFIG_DIR` or `~/.claude` | Claude Code state |
| `CODEX_HOME` | `~/.codex` | Codex state |
| `SKILLS_CLI_VERSION`, `ADD_MCP_CLI_VERSION` | `latest` | Pin the npm CLIs |
| `REPO_ARCHIVE_URL` | this repo's `main` tarball | Where the one-liner streams its payload from |
| `REPO_URL` | — | Clone that instead of streaming an archive; needs `git` |

## Dependencies

Bash, coreutils, `awk`, `sed`, and `npx` for the two upstream CLIs. Nothing else — no Python, no
`jq`, no runtime this repo has to keep in step with. The one-liner additionally needs `tar` and
either `curl` or `wget`; a clone needs neither. [`workspace-setup`](#relationship-to-workspace-setup)
installs all of it.

## macOS and Linux

The same run on both, because the paths are the same on both: the agents and the two CLIs derive
them from the home directory, not from a platform config location — `~/.claude.json`,
`~/.codex/config.toml`, `~/.config/opencode/`, `~/.agents/skills`. Nothing here consults
`~/Library/Application Support`, because nothing this repo manages is stored there.

Two of those are conditional, and both are read from the tool that writes the file. The skills
directory follows `CLAUDE_CONFIG_DIR`, which Claude Code and `skills` both honour; the config file
does not, because `add-mcp` writes `~/.claude.json` whatever that variable says. OpenCode's global
config is `opencode.jsonc` *or* `opencode.json`, whichever exists — reading a fixed `.jsonc` on a
host that has the other finds no servers at all, which reads as "every row missing" and reinstalls
them on every run.

Nothing needs bash 4, so the bash macOS actually ships is enough — 3.2, released in 2006. That
rules out `mapfile`, associative arrays, and `"${array[@]}"` for an array that might be empty:
under `set -u`, bash 3.2 calls that unbound. It rules out GNU-only flags as well, so there is no
`find -printf`, no `grep -P`, no `grep -U`, no bare `sed -i`, and symlink identity is tested with
`-ef` rather than `readlink -f`.

`awk` is the one dependency with a version floor. A pre-2019 one-true-awk reads `[[:space:]]` as
the set of those literal characters, so the config parsers would misread rather than fail; every
supported Linux and macOS 13 or later ships one that has POSIX character classes, and the preflight
proves it rather than assuming it.

The suite is run against bash 3.2.57 — the version macOS ships — with a busybox userland, which is
a third implementation of every command used here and rejects a GNU-only flag the way BSD does.

Agent configuration is read by parsing the files the agents write, not by shelling out to
`claude mcp list` or `opencode mcp list`: those health-check every server, so they need the network
and take seconds, and `claude mcp get` omits the target entirely for a server that is disabled in
the current project. Claude Code and OpenCode both write JSON, so one awk pass serves both; Codex
writes flat TOML.

The JSON reader tracks brace depth, not indentation. Two-space is what both agents write today, but
a reformatted or minified file is the same document, and an indentation-based reader returns
nothing for it — which reads as "every server is missing" and rewrites a file that was fine.

## Tests

```bash
bash tests/run.sh
```

No test reaches the network. Each builds a throwaway `$HOME` with the agent layout and replaces
`npx` and `claude` with stubs. The stubs keep flat text state and re-render the real config formats
from it, byte-for-byte as the upstream tools write them, so the indentation the parsers depend on is
itself covered. The `npx` stub drains stdin, so a caller that forgets to close it fails here rather
than in production.

`test_idempotence.sh` drives `sync.sh` end to end: converge, assert a second run reports zero
deltas, inject the drift symptoms this repo was written to fix, and assert they are repaired and the
host settles again.

`test_bootstrap.sh` runs the one-liner: it packs the working tree into an archive, serves it over
`file://`, and hands the script to `bash -s --` on stdin, which is what `curl | bash` does. It
asserts the payload is fetched, every pass runs, the host converges, a second piped run reports no
deltas, and the temporary directory is gone afterwards. `--only skills --update` is in there for a
reason: the refresh is the one child not already inside a redirected loop, so it is where an
unclosed stdin would eat the rest of the streamed script.

To run against the bash macOS ships:

```bash
docker run --rm -v "$PWD":/repo:ro bash:3.2 sh -c \
  'apk add --no-cache gawk >/dev/null; cp -R /repo /w && cd /w && bash tests/run.sh'
```

## Relationship to workspace-setup

[`workspace-setup`](https://github.com/mssaleh/workspace-setup) provisions the host: packages,
toolchains, dotfiles, SSH, containers, and the agent CLIs themselves. It changes rarely. This repo
configures what those CLIs load, and changes whenever a skill is added. Both are one piped command,
both are idempotent, and both leave nothing behind that points at their own repository.

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash
```

In that order on a new machine: `node` — and so `npx` — arrives with `workspace-setup`, along with
the three agent CLIs whose configuration this repo then converges. Afterwards they run
independently: `workspace-setup` when the host needs something, this one whenever the manifests
move.
