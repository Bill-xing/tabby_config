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

if ! declare -F codex_node_discovery >/dev/null 2>&1; then
  codex_node_discovery() {
    command -v "$1"
  }
fi

if ! declare -F codex_node >/dev/null 2>&1; then
  codex_node() {
    node "$@"
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

pretty_mermaid_lock_file() {
  printf '%s\n' "$REPO_ROOT/config/codex/pretty-mermaid-package-lock.json"
}

pretty_mermaid_file_matches_sha256() {
  local path="$1" expected="$2" actual

  [ -f "$path" ] && [ -r "$path" ] || return 1
  actual="$(sha256_file "$path")" || return 1
  [ "$actual" = "$expected" ]
}

pretty_mermaid_source_valid() {
  local target="$1"
  local skill_file="$target/SKILL.md"
  local relative expected

  while IFS=$'\t' read -r relative expected; do
    pretty_mermaid_file_matches_sha256 "$target/$relative" "$expected" || return 1
  done <<EOF
SKILL.md	$PRETTY_MERMAID_SKILL_SHA256
package.json	$PRETTY_MERMAID_PACKAGE_SHA256
scripts/render.mjs	$PRETTY_MERMAID_RENDER_SHA256
scripts/batch.mjs	$PRETTY_MERMAID_BATCH_SHA256
scripts/themes.mjs	$PRETTY_MERMAID_THEMES_SHA256
EOF

  awk '
    NR == 1 { frontmatter = ($0 == "---"); next }
    frontmatter && $0 == "---" { closed = 1; exit }
    frontmatter && $0 ~ /^name:[[:space:]]*pretty-mermaid([[:space:]]*(#.*)?)?$/ { named = 1 }
    END { exit(frontmatter && closed && named ? 0 : 1) }
  ' "$skill_file"
}

pretty_mermaid_dependencies_ready() {
  local target="$1"
  local lock_file package_file script

  lock_file="$(pretty_mermaid_lock_file)"
  package_file="$target/node_modules/beautiful-mermaid/package.json"
  [ -f "$lock_file" ] && [ -r "$lock_file" ] || return 1
  [ -f "$target/package-lock.json" ] && cmp -s "$lock_file" "$target/package-lock.json" || return 1
  [ -f "$package_file" ] && [ -r "$package_file" ] || return 1
  codex_node_discovery node >/dev/null 2>&1 || return 1

  codex_node --eval '
    const fs = require("fs");
    const lock = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const installed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const locked = lock.packages && lock.packages["node_modules/beautiful-mermaid"];
    if (!locked || typeof locked.version !== "string" || installed.version !== locked.version) process.exit(1);
  ' "$target/package-lock.json" "$package_file" || return 1
  for script in render.mjs batch.mjs themes.mjs; do
    codex_node --check "$target/scripts/$script" || return 1
  done
  codex_node --input-type=module --eval '
    const { createRequire } = await import("node:module");
    createRequire(process.argv[1])( "beautiful-mermaid" );
  ' "$target/package.json"
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

pretty_mermaid_existing_reusable() {
  local target="$1"

  [ -d "$target" ] && [ ! -L "$target" ] || return 1
  pretty_mermaid_source_valid "$target" || return 1
  if [ -d "$target/.git" ]; then
    pretty_mermaid_pinned "$target" || return 1
  fi
}

pretty_mermaid_new_stage() {
  local parent="$1" stage

  mkdir -p "$parent" || return 1
  stage="$(mktemp -d "$parent/.pretty-mermaid.stage.XXXXXX")" || return 1
  rmdir "$stage" || return 1
  printf '%s\n' "$stage"
}

pretty_mermaid_backup_target() {
  local target="$1" stamp backup suffix=1

  stamp="$(date +%Y%m%d%H%M%S)"
  backup="${target}.bak.${stamp}"
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    backup="${target}.bak.${stamp}.${suffix}"
    suffix=$((suffix + 1))
  done
  log "Backing up $target -> $backup" >&2
  mv "$target" "$backup" || return 1
  printf '%s\n' "$backup"
}

pretty_mermaid_discard_stage() {
  local stage="$1"

  [ -n "$stage" ] && [ -e "$stage" ] && rm -rf -- "$stage"
}

install_pretty_mermaid() {
  local target stage lock_file backup='' had_existing=false

  target="$(pretty_mermaid_target)"
  if pretty_mermaid_existing_reusable "$target" && ! force_install; then
    if pretty_mermaid_dependencies_ready "$target"; then
      log "Reusing valid pretty-mermaid skill: $target"
      return 0
    fi
    if ! codex_npm_discovery npm >/dev/null 2>&1 || ! codex_node_discovery node >/dev/null 2>&1; then
      warn "pretty-mermaid source installed, but Node.js/npm is required to render diagrams"
      return 0
    fi
  fi

  stage="$(pretty_mermaid_new_stage "$(dirname "$target")")" || {
    warn "cannot create pretty-mermaid staging directory"
    return 1
  }
  if ! codex_clone_repo_at_ref "$PRETTY_MERMAID_REPO" "$PRETTY_MERMAID_REF" "$stage"; then
    pretty_mermaid_discard_stage "$stage"
    warn "failed to stage pretty-mermaid skill from pinned repository"
    return 1
  fi
  if ! pretty_mermaid_source_valid "$stage" || ! pretty_mermaid_pinned "$stage"; then
    pretty_mermaid_discard_stage "$stage"
    warn "staged pretty-mermaid checkout failed pinned source validation"
    return 1
  fi

  lock_file="$(pretty_mermaid_lock_file)"
  if ! cp "$lock_file" "$stage/package-lock.json"; then
    pretty_mermaid_discard_stage "$stage"
    warn "cannot copy pinned pretty-mermaid dependency lockfile"
    return 1
  fi
  if codex_npm_discovery npm >/dev/null 2>&1 && codex_node_discovery node >/dev/null 2>&1; then
    if ! codex_npm --prefix "$stage" ci --omit=dev --ignore-scripts ||
      ! pretty_mermaid_dependencies_ready "$stage"; then
      pretty_mermaid_discard_stage "$stage"
      warn "failed to install or validate pinned pretty-mermaid runtime dependencies"
      return 1
    fi
  else
    warn "pretty-mermaid source installed, but Node.js/npm is required to render diagrams"
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    had_existing=true
    backup="$(pretty_mermaid_backup_target "$target")" || {
      pretty_mermaid_discard_stage "$stage"
      return 1
    }
  fi
  if ! mv "$stage" "$target"; then
    pretty_mermaid_discard_stage "$stage"
    if [ "$had_existing" = true ]; then
      mv "$backup" "$target" || warn "cannot restore previous pretty-mermaid skill: $backup"
    fi
    warn "cannot publish staged pretty-mermaid skill"
    return 1
  fi
}

install_codex_server() {
  codex_usable || return 1
  ensure_codex_plugin figma@openai-curated || return 1
  ensure_codex_plugin superpowers@openai-curated || return 1
  install_pretty_mermaid || return 1
  install_codex_server_config
}
