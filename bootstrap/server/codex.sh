#!/usr/bin/env bash

# Codex setup is intentionally expressed through small wrappers.  Besides
# making the commands easy to replace in tests, this keeps sourcing the file
# free of network, npm, plugin, and ~/.codex side effects.

if ! declare -F codex_command_discovery >/dev/null 2>&1; then
  codex_command_discovery() {
    command -v "$1"
  }
fi

if ! declare -F codex_npm_discovery >/dev/null 2>&1; then
  codex_npm_discovery() {
    command -v "$1"
  }
fi

if ! declare -F codex_cli >/dev/null 2>&1; then
  codex_cli() {
    codex "$@"
  }
fi

if ! declare -F codex_npm >/dev/null 2>&1; then
  codex_npm() {
    npm "$@"
  }
fi

if ! declare -F codex_clone_repo_at_ref >/dev/null 2>&1; then
  codex_clone_repo_at_ref() {
    clone_repo_at_ref "$@"
  }
fi

if ! declare -F codex_git >/dev/null 2>&1; then
  codex_git() {
    git "$@"
  }
fi

codex_usable() {
  if ! codex_command_discovery codex >/dev/null 2>&1; then
    warn 'Codex CLI is required; install Codex and ensure `codex` is on PATH'
    return 1
  fi
  if ! codex_cli --version >/dev/null 2>&1; then
    warn 'Codex CLI is unusable; `codex --version` must succeed before server setup'
    return 1
  fi
}

codex_plugin_installed() {
  local selector="$1"
  local listing status

  listing="$(codex_cli plugin list)" || {
    status=$?
    return "$status"
  }

  printf '%s\n' "$listing" |
    awk -v selector="$selector" '
      $1 == selector && ($2 == "installed" || $2 == "installed,") && \
          ($3 == "enabled" || $3 == "disabled") {
        found = 1
      }
      END { exit(found ? 0 : 1) }
    '
}

ensure_codex_plugin() {
  local selector="$1"
  local status

  case "$selector" in
    figma@openai-curated|superpowers@openai-curated) ;;
    *)
      warn "refusing to manage unapproved Codex plugin: $selector"
      return 2
      ;;
  esac

  if codex_plugin_installed "$selector"; then
    return 0
  else
    status=$?
  fi
  if [ "$status" -ne 1 ]; then
    warn 'cannot list Codex plugins; install or update Codex with `codex plugin` support'
    return "$status"
  fi

  if ! codex_cli plugin add "$selector"; then
    warn "failed to add Codex plugin: $selector"
    return 1
  fi
  if codex_plugin_installed "$selector"; then
    return 0
  else
    status=$?
  fi
  warn "Codex plugin was not installed after add: $selector"
  return "$status"
}

pretty_mermaid_target() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/skills/pretty-mermaid"
}

pretty_mermaid_source_valid() {
  local target="$1"
  local skill_file="$target/SKILL.md"
  local package_file="$target/package.json"
  local script

  [ -f "$skill_file" ] && [ -r "$skill_file" ] || return 1
  [ -f "$package_file" ] && [ -r "$package_file" ] || return 1
  for script in render.mjs batch.mjs themes.mjs; do
    [ -f "$target/scripts/$script" ] && [ -r "$target/scripts/$script" ] || return 1
  done
  awk '
    NR == 1 { frontmatter = ($0 == "---"); next }
    frontmatter && $0 == "---" { closed = 1; exit }
    frontmatter && $0 ~ /^name:[[:space:]]*pretty-mermaid([[:space:]]*(#.*)?)?$/ { named = 1 }
    END { exit(frontmatter && closed && named ? 0 : 1) }
  ' "$skill_file"
}

pretty_mermaid_dependencies_ready() {
  local target="$1"

  [ -f "$target/node_modules/beautiful-mermaid/package.json" ] &&
    [ -r "$target/node_modules/beautiful-mermaid/package.json" ]
}

pretty_mermaid_valid() {
  pretty_mermaid_source_valid "$1"
}

pretty_mermaid_pinned() {
  local target="$1"
  local current_ref

  [ -d "$target/.git" ] || return 1
  current_ref="$(codex_git -C "$target" rev-parse HEAD 2>/dev/null)" || return 1
  [ "$current_ref" = "$PRETTY_MERMAID_REF" ]
}

install_pretty_mermaid() {
  local target cloned=false

  target="$(pretty_mermaid_target)"
  if pretty_mermaid_source_valid "$target"; then
    if ! force_install || [ ! -d "$target/.git" ]; then
      log "Reusing valid pretty-mermaid skill: $target"
    else
      cloned=true
    fi
  elif [ -e "$target" ] || [ -L "$target" ]; then
    backup_existing "$target" || return 1
    cloned=true
  else
    cloned=true
  fi

  if [ "$cloned" = true ]; then
    if ! codex_clone_repo_at_ref "$PRETTY_MERMAID_REPO" "$PRETTY_MERMAID_REF" "$target"; then
      warn "failed to install pretty-mermaid skill from pinned repository"
      return 1
    fi
    if ! pretty_mermaid_source_valid "$target"; then
      warn "pretty-mermaid checkout is missing required skill source files: $target"
      return 1
    fi
    if ! pretty_mermaid_pinned "$target"; then
      warn "pretty-mermaid checkout is not pinned at $PRETTY_MERMAID_REF"
      return 1
    fi
  fi

  if pretty_mermaid_dependencies_ready "$target"; then
    return 0
  fi

  if codex_npm_discovery npm >/dev/null 2>&1; then
    if ! codex_npm --prefix "$target" install --omit=dev --ignore-scripts; then
      warn "failed to install pretty-mermaid runtime dependencies"
      return 1
    fi
    if ! pretty_mermaid_dependencies_ready "$target"; then
      warn "pretty-mermaid dependency installation did not provide beautiful-mermaid"
      return 1
    fi
  else
    warn "pretty-mermaid source installed, but Node.js/npm is required to render diagrams"
  fi
}

install_codex_server() {
  codex_usable || return 1
  ensure_codex_plugin figma@openai-curated || return 1
  ensure_codex_plugin superpowers@openai-curated || return 1
  install_pretty_mermaid || return 1
  install_codex_server_config
}
