# agents-setup

Synchronize skills, MCP servers, and Claude Code plugins from manifests using
the skills CLI and each agent's native configuration commands.

## Run

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash -s -- --dry-run

# From a checkout:
./sync.sh --dry-run
./sync.sh
```

Piped execution downloads a temporary repository payload and removes it on exit.
`wget -qO- … | bash` also works. `REPO_ARCHIVE_URL` can select another tarball,
including a local `file://` archive; `REPO_URL` selects a Git clone instead.

The script validates the manifests, installs missing skills, prunes fetched skills
absent from the manifest, builds skill mirrors, reconciles MCP servers, installs
declared Claude plugins, and verifies the resulting configuration. A converged
run writes nothing. Verification checks configuration and skill payloads; it
does not establish that a remote MCP service is reachable or authenticated.

## Configuration ownership

| Concern | Manifest | Writer |
|---|---|---|
| Skills | `manifests/skills.tsv` | `npx skills` |
| MCP servers | `manifests/mcp.tsv` | `claude mcp`, `codex mcp`, `opencode mcp` |
| Claude plugins | `manifests/plugins.tsv` | `claude plugin` |

MCP entries use native user configuration. Claude commands pass `--scope user`.
Codex commands use `--url` for Streamable HTTP and a command after `--` for stdio.
OpenCode **1.18** named adds accept the same URL/command forms and write global
configuration without a scope flag. OpenCode V2 has a different configuration
schema and scope interface and is outside this script's supported version line.

| Agent | Personal skills | User MCP configuration |
|---|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR/skills` or `~/.claude/skills` | `$CLAUDE_CONFIG_DIR/.claude.json` or `~/.claude.json` |
| Codex | `~/.agents/skills`; legacy `$CODEX_HOME/skills` mirror | `$CODEX_HOME/config.toml` |
| OpenCode 1.18 | `~/.agents/skills`, Claude skills, and its config directory's `skill(s)` folders | `$XDG_CONFIG_HOME/opencode/opencode.json` or `.jsonc` |

Codex's current [skill discovery](https://learn.chatgpt.com/docs/customization/skills)
includes the shared store. The Codex mirror supports the legacy directory.
Claude needs its mirror. OpenCode reads the default shared store directly.

Native path behavior was checked with Claude Code 2.1.295, Codex CLI 0.162.0, and
OpenCode 1.18.35. OpenCode named adds prefer `.json` when both files exist, fall
back to `.jsonc`, and create `.json` when neither exists. Its
[command source](https://github.com/anomalyco/opencode/blob/v1.18.35/packages/opencode/src/cli/cmd/mcp.ts)
defines this behavior. User scope and replacement behavior for Claude are
documented in its [MCP reference](https://code.claude.com/docs/en/mcp).

OpenCode merges both global files, and `.jsonc` can override entries in `.json`.
Verification reads `opencode --pure debug config` outside a project to inspect
that merged configuration. If an override defeats a native write, verification
reports the unmet target instead of claiming convergence.

## Manifests and reconciliation

`skills.tsv` contains `source`, comma-separated `skills`, and `mode` (`select` or
`whole`). Names come from each skill's `name:` field. Discover available names
with `npx skills add <source> -l`. Only missing skills are installed; `--update`
refreshes installed skills through the upstream CLI. The CLI owns its lock file.
Skills without lock entries are preserved and mirrored.

`mcp.tsv` contains `name`, `transport` (`stdio`, `http`, or `sse`), `target`, and
comma-separated `agents` (`claude-code`, `codex`, `opencode`). Stdio targets are
npm package specifications. Remote targets are complete URLs. Codex does not
support legacy SSE, so an SSE row naming Codex fails validation.

A server is satisfied only when its name resolves to the declared target and
is enabled. Transport labels differ between agents, so verification compares
remote-versus-stdio and target identity. Stdio identity ignores `npx`, resolved
versions, and install directories unless the manifest explicitly requests a
version. When existing agents agree on an installed executable, an agent missing
that server receives the same executable. Different valid invocations are
reported without being rewritten.

Claude rejects adding an existing name at the same scope, so replacing an
incorrect entry removes that user entry first. Codex and OpenCode named adds
replace existing entries. Failed native commands are reported and cause a
nonzero exit. A later run repairs any incomplete replacement.

`plugins.tsv` contains `agent`, `marketplace`, `marketplace_source`, and `plugin`.
Plugin installation currently supports Claude Code. Undeclared plugins and MCP
servers are reported and preserved, including desktop-managed integrations.
Project-scoped Claude servers and servers disabled in the current directory
are reported without changing those project decisions.

`--prune-duplicate-mcp` removes an undeclared name for a declared endpoint using
native exact-name removal in Claude and Codex. OpenCode 1.18 has no native MCP
remove command: a requested duplicate removal is reported as unresolved and
exits nonzero. Its config must be edited separately to remove that entry.

## Options and environment

| Flag | Effect |
|---|---|
| `--dry-run` | Report the plan without writing; verification reports what the plan cannot fix |
| `--only skills\|mcp\|plugins\|verify` | Run one pass |
| `--update` | Refresh installed skills from upstream |
| `--prune-plugin-cache` | Delete marketplace clones with no registered marketplace |
| `--prune-duplicate-mcp` | Remove duplicate MCP names where native removal exists |

| Variable | Default or behavior |
|---|---|
| `AGENTS_HOME` | `~/.agents`, the shared skill store root |
| `AGENTS_LOCK` | `$XDG_STATE_HOME/skills/.skill-lock.json` or `~/.agents/.skill-lock.json` |
| `CLAUDE_CONFIG_DIR` | Native Claude config directory override |
| `CLAUDE_HOME` | Skill/plugin inspection root, defaulting to `$CLAUDE_CONFIG_DIR` or `~/.claude` |
| `CODEX_HOME` | `~/.codex`; also honored by native Codex commands |
| `XDG_CONFIG_HOME` | `~/.config`; determines OpenCode's global config directory |
| `SKILLS_CLI_VERSION` | `latest`, the skills CLI release selector |
| `REPO_ARCHIVE_URL` | This repository's `main` tarball |
| `REPO_URL` | Optional Git clone source instead of the archive |

Dependencies are Bash 3.2 or newer, coreutils, POSIX `awk`, `sed`, `npx`, Claude
Code, Codex CLI, and OpenCode 1.18. OpenCode is also required to inspect effective
MCP configuration; Claude and Codex are needed when their passes apply changes.
The streamed entry point also needs `tar` and either `curl` or `wget`. No
additional parser runtime is required.

Every external command runs with stdin closed so it cannot consume manifest
rows or the remainder of a piped script. Config readers and OpenCode's native
config inspection do not run MCP health checks. Mirror verification uses `-ef`
to confirm that each link resolves to its own shared payload.

## Verification

```bash
bash tests/run.sh

# Bash 3.2 and an Alpine userland:
docker run --rm -v "$PWD":/repo:ro bash:3.2 sh -c \
  'apk add --no-cache gawk >/dev/null; cp -R /repo /w && cd /w && bash tests/run.sh'
```

The suite uses temporary homes and stubs for the skills CLI and native agent
commands. It checks target repair, disabled entries, exact-name removal,
unsupported OpenCode removal, dry runs, convergence, and streamed execution.
It requires no network. Changes to native command integration also require an
isolated check against the installed CLIs; stubs alone do not prove compatibility.

[`workspace-setup`](https://github.com/mssaleh/workspace-setup) provisions the host
and installs the agent CLIs. This repository configures what those CLIs load.
