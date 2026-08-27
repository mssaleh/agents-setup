#!/usr/bin/env bash
# The config readers depend on structure, not on how a file happens to be laid
# out. Every fixture here is the same document written differently; each must
# produce the same table.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_parsers
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/agentcfg.sh
. "$REPO_DIR/lib/agentcfg.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/agents-setup-parsers.XXXXXX")
trap 'rm -rf "$work"' EXIT

cat > "$work/2space.json" <<'EOF'
{
  "other": {},
  "mcp": {
    "docs": {
      "type": "remote",
      "url": "https://docs.example/mcp",
      "enabled": true
    },
    "tools": {
      "type": "local",
      "command": [
        "npx",
        "-y",
        "tools-mcp@latest"
      ],
      "enabled": false
    }
  }
}
EOF

# Same document, four-space indent, with the comments JSONC allows.
cat > "$work/4space.json" <<'EOF'
/* hand reformatted */
{
    "other": {},
    // the servers
    "mcp": {
        "docs": {
            "type": "remote",
            "url": "https://docs.example/mcp",
            "enabled": true
        },
        "tools": {
            "type": "local",
            "command": [
                "npx",
                "-y",
                "tools-mcp@latest"
            ],
            "enabled": false
        }
    }
}
EOF

printf '{"other":{},"mcp":{"docs":{"type":"remote","url":"https://docs.example/mcp","enabled":true},"tools":{"type":"local","command":["npx","-y","tools-mcp@latest"],"enabled":false}}}\n' \
  > "$work/minified.json"
sed 's/^  */\t/' "$work/2space.json" > "$work/tabs.json"

expected=$(printf 'docs\tremote\thttps://docs.example/mcp\ttrue\ntools\tstdio\ttools-mcp@latest\tfalse')
for f in 2space 4space minified tabs; do
  assert_eq "$f parses to the same table" "$(json_mcp_block "$work/$f.json" mcp)" "$expected"
done

# Claude Code's shape: scalar "command" plus a separate "args".
cat > "$work/claude.json" <<'EOF'
{
  "mcpServers": {
    "tools": {
      "command": "npx",
      "args": [
        "-y",
        "tools-mcp@latest"
      ]
    }
  }
}
EOF
assert_eq "scalar command + args normalises past npx" \
  "$(json_mcp_block "$work/claude.json" mcpServers)" "$(printf 'tools\tstdio\ttools-mcp@latest\ttrue')"

# A URL containing braces or an escaped quote must not disturb the depth count.
cat > "$work/tricky.json" <<'EOF'
{
  "mcp": {
    "weird": {
      "type": "remote",
      "url": "https://x.example/{tenant}/mcp?q=a\"b"
    }
  }
}
EOF
assert_contains "braces inside a string do not shift depth" \
  "$(json_mcp_block "$work/tricky.json" mcp)" 'https://x.example/{tenant}/mcp'

# The wanted key must be the top-level one, not a same-named key nested deeper.
cat > "$work/nested.json" <<'EOF'
{
  "projects": {
    "/somewhere": {
      "mcpServers": {
        "project-only": {
          "type": "http",
          "url": "https://project.example/mcp"
        }
      }
    }
  },
  "mcpServers": {
    "user-scope": {
      "type": "http",
      "url": "https://user.example/mcp"
    }
  }
}
EOF
assert_eq "a nested block of the same name is not user scope" \
  "$(json_mcp_block "$work/nested.json" mcpServers)" \
  "$(printf 'user-scope\tremote\thttps://user.example/mcp\ttrue')"

# …and the project reader must not claim the user-scope block, which sits after
# it in the file. An empty mcpServers must not leak its key to the next object.
CLAUDE_CONFIG="$work/nested.json"
assert_eq "project reader finds only the project server" \
  "$(claude_project_mcp)" "$(printf 'project-only\t/somewhere')"

cat > "$work/empty-proj.json" <<'EOF'
{
  "projects": {
    "/a": {
      "mcpServers": {}
    },
    "/b": {
      "metrics": {
        "p99": {
          "value": 1
        }
      }
    }
  },
  "mcpServers": {
    "user-scope": {
      "type": "http",
      "url": "https://user.example/mcp"
    }
  }
}
EOF
CLAUDE_CONFIG="$work/empty-proj.json"
assert_eq "an empty project block leaks nothing into the next" "$(claude_project_mcp)" ""

# TOML: enabled, quoted names with dots, and sub-tables that are not servers.
cat > "$work/config.toml" <<'EOF'
model = "test"

[mcp_servers.off]
type = "http"
url = "https://off.example/mcp"
enabled = false

[mcp_servers."has.dots"]
command = "npx"
args = [ "-y", "dotted@1" ]

[mcp_servers.node_repl]
command = "/opt/node_repl"

  [mcp_servers.node_repl.env]
  FOO = "bar"

[unrelated]
key = "value"
EOF
got=$(toml_mcp_servers "$work/config.toml")
assert_contains "toml reads enabled = false"        "$got" "$(printf 'off\tremote\thttps://off.example/mcp\tfalse')"
assert_contains "toml reads a quoted dotted name"   "$got" "$(printf 'has.dots\tstdio\tdotted@1\ttrue')"
assert_contains "toml keeps a non-npx command"      "$got" "$(printf 'node_repl\tstdio\t/opt/node_repl\ttrue')"
assert_eq       "an env sub-table is not a server"  "$(grep -c 'node_repl.env' <<< "$got")" "0"
assert_eq       "an unrelated table is not a server" "$(grep -c '^unrelated' <<< "$got")" "0"

# Claude Code switches a server off per directory under disabledMcpServers —
# a different key from disabledMcpjsonServers, and one a user-scope check misses.
cat > "$work/disabled.json" <<'EOF'
{
  "projects": {
    "/home/me/one": {
      "disabledMcpjsonServers": [],
      "disabledMcpServers": [
        "docs",
        "tools"
      ]
    },
    "/home/me/two": {
      "disabledMcpServers": [
        "other"
      ]
    }
  },
  "mcpServers": {}
}
EOF
CLAUDE_CONFIG="$work/disabled.json"
assert_eq "reads the disabled list for one directory" \
  "$(claude_disabled_in /home/me/one | tr '\n' ' ')" "docs tools "
assert_eq "and not another directory's"  "$(claude_disabled_in /home/me/two | tr '\n' ' ')" "other "
assert_eq "an unknown directory disables nothing" "$(claude_disabled_in /home/me/three)" ""

# A missing file is empty, not an error.
assert_eq "a missing json file yields nothing" "$(json_mcp_block "$work/nope.json" mcp)" ""
assert_eq "a missing toml file yields nothing" "$(toml_mcp_servers "$work/nope.toml")" ""

test_summary
