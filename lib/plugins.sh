#!/usr/bin/env bash
# lib/plugins.sh — install the allowlisted plugins, and only those.
#
# A plugin ships commands, agents, hooks and an MCP server as one unit, so it is
# the wrong shape for anything a skill and an MCP row can express. The allowlist
# is short by intent. Nothing here uninstalls: a plugin present but unlisted is
# reported, because removing somebody's deliberate install is not convergence.
# shellcheck shell=bash

plugins_converge() {
  local row agent marketplace source plugin
  while IFS= read -r row; do
    agent=$(manifest_field "$row" 1)
    marketplace=$(manifest_field "$row" 2)
    source=$(manifest_field "$row" 3)
    plugin=$(manifest_field "$row" 4)
    [[ "$agent" == claude-code ]] || { warn "no plugin installer for agent '$agent'"; continue; }
    command -v claude >/dev/null 2>&1 || { info "claude not installed here, skipping plugins"; return 0; }

    if claude_known_marketplaces | grep -qxF "$marketplace"; then
      ok "marketplace $marketplace registered"
    else
      delta "registering marketplace $marketplace ($source)"
      run claude plugin marketplace add "$source" || warn "could not add marketplace $source"
    fi

    if claude_installed_plugins | grep -qxF "$plugin@$marketplace"; then
      ok "plugin $plugin@$marketplace installed"
    else
      delta "installing plugin $plugin@$marketplace"
      run claude plugin install "$plugin@$marketplace" || warn "could not install $plugin@$marketplace"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/plugins.tsv")
}

plugins_report_undeclared() {
  local declared name
  declared=$(manifest_rows "$MANIFEST_DIR/plugins.tsv" | awk -F'\t' '{print $4"@"$2}' | sort -u)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$declared" || info "claude: plugin '$name' installed but not declared (left alone)"
  done < <(claude_installed_plugins)
  return 0
}

# plugins_report_orphan_cache — marketplace caches with no registered marketplace
# and no installed plugin. Abandoned `claude plugin install` experiments leave the
# full clone behind; agent-browser alone is 29 MB. Deleting is opt-in.
plugins_report_orphan_cache() {
  local cache="$CLAUDE_HOME/plugins/cache" dir mkt size total=0
  [[ -d "$cache" ]] || return 0
  while IFS= read -r dir; do
    mkt=$(basename "$dir")
    claude_known_marketplaces | grep -qxF "$mkt" && continue
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    total=$((total + 1))
    if [[ -n "${PRUNE_PLUGIN_CACHE:-}" ]]; then
      delta "removing orphaned plugin cache $mkt ($size)"
      run rm -rf "$dir"
    else
      info "orphaned plugin cache: $mkt ($size) — rerun with --prune-plugin-cache to remove"
    fi
  done < <(find "$cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  ((total == 0)) && ok "no orphaned plugin caches"
  return 0
}
