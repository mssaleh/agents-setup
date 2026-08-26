# agents-setup

One manifest per concern, one idempotent script, three coding agents that agree.

Claude Code, Codex and OpenCode each want their skills, MCP servers and plugins configured in a
different place and a different format. Configuring them one at a time produces silent drift:
servers that exist in one agent and not another, servers overwritten by a name collision, skills
that resolve in one agent and dangle in the next. This repo makes the manifests authoritative and
converges every agent onto them.

```bash
git clone git@github.com:mssaleh/agents-setup.git
cd agents-setup
./sync.sh --dry-run     # report what would change
./sync.sh               # converge, then verify
```

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
2. **prune** — `skills remove` anything in the store or the lock that no row declares.
3. **refresh** — `--update` only: `skills update -g -y`, upstream's own update over the lock, which
   prune has already reduced to exactly the manifest.
4. **mirror** — make `~/.claude/skills` and `$CODEX_HOME/skills` match the store: link what is
   declared, drop dangling and undeclared links, and replace a full copy that shadows a managed
   skill. Undeclared local directories are left alone — Codex ships its own `skills/.system/`.
5. **mcp** — install each row into the agents that lack it *or point somewhere else*.
6. **plugins** — register the marketplace and install the allowlist; report anything else.
7. **verify** — read every agent's own artifact back and exit non-zero if the manifest is unmet.

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

Transport *labels* are not compared, because the agents disagree about them — the same SSE endpoint
is `sse` to Claude Code, `remote` to OpenCode, and reported as `streamable_http` by Codex. What is
compared is remote-versus-stdio and the URL or package itself, which every agent agrees on.

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

Every child command runs with stdin closed. These execute inside `while read` loops, and `npx`
reads stdin, so an open descriptor lets the first iteration swallow the rest of the loop's input.

## The manifests

`manifests/skills.tsv` — `source`, `skills`, `mode`.

The `skills` column is authoritative, and lists names as they appear in the store. A name is the
`name:` in the skill's own `SKILL.md`, which is what `--skill` matches; it is not always the repo's
directory name (`skills/react-best-practices/` installs as `vercel-react-best-practices`). Take
names from `npx skills add <source> -l`. `mode` is `select` when the repo carries more than you
want, `whole` when the source spec already names exactly one skill.

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
  removing it breaks the in-app browser.
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

| Variable | Default | Purpose |
|---|---|---|
| `AGENTS_HOME` | `~/.agents` | Shared skill store root |
| `AGENTS_LOCK` | `$XDG_STATE_HOME/skills/` or `~/.agents/` | Skill lock, following upstream's own rule |
| `CLAUDE_HOME` | `~/.claude` | Claude Code state |
| `CODEX_HOME` | `~/.codex` | Codex state |
| `SKILLS_CLI_VERSION`, `ADD_MCP_CLI_VERSION` | `latest` | Pin the npm CLIs |

## Dependencies

Bash, coreutils, `awk`, `sed`, and `npx` for the two upstream CLIs. Nothing else — no Python, no
`jq`, no runtime this repo has to keep in step with.

Linux and macOS. Nothing here needs bash 4, so the bash macOS actually ships is enough: no
`mapfile`, no associative arrays, no `find -printf`, and symlink identity is tested with `-ef`
rather than `readlink -f`.

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

## Relationship to workspace-setup

[`workspace-setup`](https://github.com/mssaleh/workspace-setup) provisions the host: packages,
toolchains, dotfiles, SSH, containers, and the agent CLIs themselves. It changes rarely. This repo
configures what those CLIs load, and changes whenever a skill is added. Run `workspace-setup` first
on a new machine; run `./sync.sh` here whenever the manifests move.
