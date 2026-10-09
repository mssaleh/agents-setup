# Project guidance

Use the current branch. Create branches and pull requests only when requested.
Commit only when requested; push only when separately requested.

## Toolchain and verification

Use Bash, coreutils, `awk`, `sed`, `npx skills`, and the installed agent CLIs.
Do not add Python, `jq`, or another runtime, including for one-off repository work.
Use Bash 3.2 syntax and BSD-compatible flags. Empty arrays under `set -u` need
`${array[@]+"${array[@]}"}`. Use `-ef` for symlink identity and name stdin for BSD
commands that require it, such as `paste -sd, -`.

Run `bash tests/run.sh`. For shell changes, also run the README's Bash 3.2
container command before claiming portability. Verify native command behavior
in an isolated temporary home when changing agent configuration commands.

Keep comments concise and limited to non-obvious current behavior. Cite the
upstream version or source beside a dependency on undocumented CLI behavior.

## Entry points and manifests

`sync.sh` runs both from a checkout and through `curl | bash`. Piped execution
has no `BASH_SOURCE[0]`; use its `:-` fallback and `$REPO_DIR` for payload files.
Keep the header comment contiguous from line 2 because `--help` prints it.
Close every child command's stdin through `run()`. Bootstrap commands close
their own stdin before `run()` is available.

Names and targets belong in `manifests/`. Compare a server's declared name,
remote-versus-stdio kind, target, and enabled state. Compare URLs whole. For
stdio, compare the package identity rather than the runner or install directory;
an explicitly versioned target requires that version. A mirror must resolve to
its own shared payload, checked with `-ef`.

## State ownership

Use each agent's native MCP commands to write configuration. Claude Code uses
user scope; its add command rejects an existing name, so replacement requires
native removal first. OpenCode 1.18 named adds write global configuration and
have no native MCP removal command. Report unsupported removal without editing
its configuration directly.

Read the artifacts each native command writes. Honor native configuration paths
and environment variables. Dry-run verification subtracts only the recorded
plan; real verification reads the resulting host state.

The skills CLI owns `.skill-lock.json`; never write it directly. Install only
missing skills, refresh only with `--update`, and prune only lock entries absent
from the manifest. Skills outside the lock are user-owned. Preserve undeclared
MCP servers and plugins; `--prune-duplicate-mcp` authorizes only exact-name removal
of a second name for a declared endpoint, where a native command supports it.
