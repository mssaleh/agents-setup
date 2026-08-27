# agents-setup

One manifest per concern, one idempotent script, three coding agents that agree.

Claude Code, Codex and OpenCode each want their skills, MCP servers and plugins configured in a
different place and a different format. Configuring them one at a time produces silent drift:
servers that exist in one agent and not another, servers overwritten by a name collision, skills
that resolve in one agent and dangle in the next.

## Quick start

```bash
# One-shot:
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash

# Report what would change first:
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash -s -- --dry-run

# On a Linux host with wget but not curl:
wget -qO- https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash

# Or clone and run:
git clone https://github.com/mssaleh/agents-setup.git && cd agents-setup && ./sync.sh
```

Piped in, the script downloads the manifests to a temporary directory, converges the host and
deletes them. What is left is ordinary agent configuration under `$HOME`; nothing points back
here. Flags work after `bash -s --`, and `REPO_ARCHIVE_URL` aims the payload elsewhere — a
`file://` archive needs neither network nor download tool.

A converged host prints no deltas, writes nothing, and finishes in a few seconds.

## What it manages

| Layer | Manifest | Installer | Agents |
|---|---|---|---|
| Skills | `manifests/skills.tsv` | `npx skills` | Claude Code, Codex, OpenCode |
| MCP servers | `manifests/mcp.tsv` | `npx add-mcp` | Claude Code, Codex, OpenCode |
| Plugins | `manifests/plugins.tsv` | `claude plugin` | Claude Code |

## Where each agent actually looks

Taken from the shipped binaries, not from documentation:

| Agent | Skills | MCP servers |
|---|---|---|
| Claude Code | `~/.claude/skills/<name>/` | `~/.claude.json` → `mcpServers` |
| Codex | `$CODEX_HOME/skills/<name>/` | `~/.codex/config.toml` → `[mcp_servers.*]` |
| OpenCode | `~/.agents/skills/`, `~/.claude/skills/`, `~/.config/opencode/skill(s)/` | `~/.config/opencode/opencode.jsonc` → `mcp` |

OpenCode reads the shared store directly, so it is never mirrored into. Claude Code and Codex read
only their own directories, so the store is symlinked into both.

## How a run proceeds

The manifests are validated first — field counts, known modes and transports, known agent names, no
duplicates, no CRLF. Then:

1. **install** — `skills add … -a universal` for declared skills not in the store, and nothing else.
2. **prune** — `skills remove` what the lock records and no row declares.
3. **refresh** — `--update` only: `skills update -g -y`.
4. **mirror** — link everything the store holds into `~/.claude/skills` and `$CODEX_HOME/skills`,
   drop links to what it no longer holds, replace a full copy shadowing a managed skill.
5. **mcp** — install each row into the agents that lack it or point somewhere else.
6. **plugins** — register the marketplace and install the allowlist; report anything else.
7. **verify** — read every agent's own artifact back and exit non-zero if the manifest is unmet.

## Design notes

These are the things that are not obvious from the code, and each was a real defect first.

**Identity is the target, never the name.** A row is satisfied only when the agent resolves the
name to the declared target. `mcp add copilotkit …` run three times with three different URLs
leaves one server holding a name that describes none of them, and a name-only check calls that
converged. A mirrored skill is the same problem: a link to the wrong skill still resolves and still
has a `SKILL.md`, so each is checked with `-ef` against its own payload. A server at the right URL
with `enabled = false` is not satisfied either.

**Transport labels are not compared** — the same SSE endpoint is `sse` to Claude Code, `remote` to
OpenCode, `streamable_http` to Codex. What is compared is remote-versus-stdio and the URL or
package.

**A stdio row names a package, not an invocation.** The `npx` runner is stripped, and so are the
install directory and the resolved version: `npx -y next-devtools-mcp@latest` and
`~/.npm/packages/bin/next-devtools-mcp` are one server started two ways. Timed over a real MCP
`initialize` handshake, npx costs 0.33 s against 0.11 s for the installed binary, and 4.95 s on a
cold npx cache. A row that *pins* a version accepts only that version.

An agent that lacks the row gets whatever the agents that have it already run, when they agree —
otherwise adding an agent is what makes a host start one server two ways. The tradeoff of an
absolute path is that it fails loudly if the package is uninstalled and no longer tracks upstream;
the alternative is one agent paying the launch cost the others do not.

**A skill you wrote needs no row.** The manifest is authoritative over what a source installed.
`skills add` records a `source` and `sourceUrl` per entry, so the lock is what tells the two apart,
and prune's set is the lock minus the manifest. A skill of your own is mirrored like any other,
reported once a run as `not installed from a source, left alone`, and never anybody's to delete.
Being wrong in that direction costs a stale directory; the other direction costs work nobody can
get back.

**A dry run reports what it would *not* fix.** The passes apply nothing, so verification reads the
host as it stands — and read literally that repeats the whole plan back under ✗. An unconfigured
machine reported 131 failures and exited non-zero. Each pass records what it would do and
verification subtracts it; findings are grouped per kind, not per name. The ledger is consulted
under `--dry-run` alone.

**A second name for a declared endpoint** — `copilotkit-mcp` beside `copilotkit` — is the collision
from the other side. Nothing is overwritten; the agent opens the endpoint twice and offers every
tool twice. `--prune-duplicate-mcp` removes it. That pass declines one case: `add-mcp remove` matches
`serverName.includes(query)` and `-y` accepts every match, so a name that is a substring of another
is reported rather than risked.

### What the upstream CLIs require

Each of these fails quietly rather than loudly:

- **`skills add` writes the store only when a universal agent is a target** — an agent whose
  `skillsDir` is `.agents/skills`. `codex` and `opencode` are; `claude-code` is not, so `-a codex`
  writes the store and never `~/.codex/skills`, while `-a claude-code` writes a full copy that
  shadows it. `universal` means the store and nothing else.
- **`-s` and `-a` repeat, not comma-separate.** `--skill a,b` is one skill named `a,b`, matches
  nothing, and exits 0. `add-mcp` rejects a joined `-a` list as "Invalid agents".
- **`skills add` re-downloads whatever it is given**, so asking for everything rewrote all 35
  payloads on every run and reported no change. Only missing names are requested.
- **Every child runs with stdin closed.** `npx` reads stdin, which would drain the enclosing
  `while read` loop — or, piped from curl, the script bash has not finished reading.

## The manifests

`manifests/skills.tsv` — `source`, `skills`, `mode`. Names are the `name:` in each `SKILL.md`,
which is what `--skill` matches; not always the repo's directory name. Take them from
`npx skills add <source> -l`. `mode` is `select` when the repo carries more than you want, `whole`
when the source spec already names one skill.

`manifests/mcp.tsv` — `name`, `transport`, `target`, `agents`. The name is set here, never on a
command line. Every row installs at user scope: `claude mcp add` defaults to *project* scope.

`manifests/plugins.tsv` — `agent`, `marketplace`, `marketplace_source`, `plugin`. Both marketplace
name and source are recorded because they need not match. The list is short by intent: a plugin
ships commands, agents, hooks and an MCP server as one unit, so it earns a row only when a skill
plus an MCP row cannot express the same thing.

```bash
npx skills find <query>              # or: npx add-mcp find <keyword>
$EDITOR manifests/skills.tsv
./sync.sh --dry-run && ./sync.sh
```

## What it will not do

- **Uninstall a plugin.** Reported and left.
- **Remove an undeclared MCP server.** Codex's `node_repl` is injected by the ChatGPT desktop app;
  removing it breaks the in-app browser. `--prune-duplicate-mcp` is the one opt-in exception.
- **Remove a skill the lock never fetched.** That is somebody's own work.
- **Rewrite a project-scoped Claude server.** Reported with the directory it is trapped in.
- **Edit the skill lock.** That file belongs to `skills`.
- **Delete an orphaned plugin cache.** Sizes are reported; `--prune-plugin-cache` opts in.

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Report every change without writing |
| `--only skills\|mcp\|plugins\|verify` | Run one pass |
| `--update` | Also pull upstream changes into installed skills |
| `--prune-plugin-cache` | Also delete marketplace clones with no registered marketplace |
| `--prune-duplicate-mcp` | Also remove an undeclared server duplicating a declared row's target |

| Variable | Default | Purpose |
|---|---|---|
| `AGENTS_HOME` | `~/.agents` | Shared skill store root |
| `AGENTS_LOCK` | `$XDG_STATE_HOME/skills/` or `~/.agents/` | Skill lock, following upstream's rule |
| `CLAUDE_HOME` | `$CLAUDE_CONFIG_DIR` or `~/.claude` | Claude Code state |
| `CODEX_HOME` | `~/.codex` | Codex state |
| `SKILLS_CLI_VERSION`, `ADD_MCP_CLI_VERSION` | `latest` | Pin the npm CLIs |
| `REPO_ARCHIVE_URL` | this repo's `main` tarball | Where the one-liner streams its payload from |
| `REPO_URL` | — | Clone that instead; needs `git` |

## Dependencies

Bash, coreutils, `awk`, `sed`, and `npx` for the two upstream CLIs. No Python, no `jq`. The
one-liner also needs `tar` and either `curl` or `wget`.

## macOS and Linux

The same run on both: every path is homedir-derived, so nothing here consults
`~/Library/Application Support`. Two are conditional and both follow the tool that writes the file
— the skills directory honours `CLAUDE_CONFIG_DIR`, the config file does not because `add-mcp`
writes `~/.claude.json` regardless; and OpenCode's global config is `opencode.jsonc` *or*
`opencode.json`, whichever exists.

Nothing needs bash 4, so bash 3.2 is enough: no `mapfile`, no associative arrays, and no
`"${array[@]}"` for a possibly-empty array, which 3.2 calls unbound under `set -u`. No GNU-only
flags either — no `find -printf`, `grep -P`, `grep -U` or bare `sed -i`, and `-ef` rather than
`readlink -f`. `awk` needs POSIX character classes, which the preflight proves rather than assumes.

Agent configuration is parsed from the files the agents write, not via `claude mcp list`: those
health-check every server, so they need the network, and `claude mcp get` omits the target for a
server disabled in the current project. The JSON reader tracks brace depth, not indentation.

## Tests

```bash
bash tests/run.sh

# against the bash macOS ships:
docker run --rm -v "$PWD":/repo:ro bash:3.2 sh -c \
  'apk add --no-cache gawk >/dev/null; cp -R /repo /w && cd /w && bash tests/run.sh'
```

No test reaches the network. Each builds a throwaway `$HOME` and replaces `npx` and `claude` with
stubs that keep flat text state and re-render the real config formats from it, byte-for-byte. The
`npx` stub drains stdin, so a caller that forgets to close it fails here rather than in production.

`test_idempotence.sh` drives `sync.sh` end to end. `test_dirty_host.sh` is built from a real
unconverged machine. `test_bootstrap.sh` runs the one-liner over a `file://` archive.

## Relationship to workspace-setup

[`workspace-setup`](https://github.com/mssaleh/workspace-setup) provisions the host: packages,
toolchains, dotfiles, SSH, containers, and the agent CLIs themselves. This repo configures what
those CLIs load. On a new machine, in this order:

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash
```
