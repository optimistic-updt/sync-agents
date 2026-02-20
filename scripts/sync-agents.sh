#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
# Each provider: name | root dir | skills subdir | agents subdir | agent suffix
PROVIDERS=(
  "claude|.claude|skills|agents|.md"
  "github|.github|skills|agents|.agent.md"
  "opencode|.opencode|skills|agents|.md"
  "codex|.codex|skills|agents|.md"
)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/.agents"

# ─── Helpers ─────────────────────────────────────────────────────────────────
created=0
skipped=0
removed=0
warned=0

log_create() { echo "  + $1"; created=$((created + 1)); }
log_skip()   { echo "  . $1 (up to date)"; skipped=$((skipped + 1)); }
log_remove() { echo "  - $1 (stale)"; removed=$((removed + 1)); }
log_warn()   { echo "  ! $1 (exists as real file, skipping)"; warned=$((warned + 1)); }

CLAUDE_MODELS="haiku sonnet opus"

# Transform model frontmatter: [sonnet, gpt-5.2-codex] → sonnet
# Reads stdin, writes stdout. Only modifies the model: line in frontmatter.
filter_claude_model() {
  local in_frontmatter=false
  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      if $in_frontmatter; then
        in_frontmatter=false
      else
        in_frontmatter=true
      fi
      echo "$line"
    elif $in_frontmatter && [[ "$line" =~ ^model:\ *\[(.+)\]$ ]]; then
      local models="${BASH_REMATCH[1]}"
      local claude_model=""
      IFS=',' read -ra items <<< "$models"
      for item in "${items[@]}"; do
        item="$(echo "$item" | xargs)"  # trim whitespace
        for cm in $CLAUDE_MODELS; do
          if [[ "$item" == "$cm"* ]]; then
            claude_model="$item"
            break 2
          fi
        done
      done
      if [[ -n "$claude_model" ]]; then
        echo "model: $claude_model"
      fi
    else
      echo "$line"
    fi
  done
}

# ─── Sync Skills ─────────────────────────────────────────────────────────────
sync_skills() {
  local provider_name="$1" root_dir="$2" skills_dir="$3"
  local provider_skills="$REPO_ROOT/$root_dir/$skills_dir"
  local source_skills="$AGENTS_DIR/skills"

  mkdir -p "$provider_skills"

  echo "[$provider_name] Syncing skills → $root_dir/$skills_dir/"

  # Create/update symlinks for each skill directory
  for skill_path in "$source_skills"/*/; do
    [ -d "$skill_path" ] || continue
    local skill_name
    skill_name="$(basename "$skill_path")"
    local link_path="$provider_skills/$skill_name"
    local rel_target="../../.agents/skills/$skill_name"

    if [ -L "$link_path" ]; then
      local current_target
      current_target="$(readlink "$link_path")"
      if [ "$current_target" = "$rel_target" ]; then
        log_skip "$root_dir/$skills_dir/$skill_name"
        continue
      fi
      rm "$link_path"
    elif [ -e "$link_path" ]; then
      log_warn "$root_dir/$skills_dir/$skill_name"
      continue
    fi

    ln -s "$rel_target" "$link_path"
    log_create "$root_dir/$skills_dir/$skill_name → $rel_target"
  done

  # Remove stale symlinks
  for link_path in "$provider_skills"/*; do
    [ -L "$link_path" ] || continue
    local link_name
    link_name="$(basename "$link_path")"
    if [ ! -d "$source_skills/$link_name" ]; then
      rm "$link_path"
      log_remove "$root_dir/$skills_dir/$link_name"
    fi
  done
}

# ─── Sync Agents ─────────────────────────────────────────────────────────────
sync_agents() {
  local provider_name="$1" root_dir="$2" agents_dir="$3" agent_suffix="$4"
  local provider_agents="$REPO_ROOT/$root_dir/$agents_dir"
  local source_agents="$AGENTS_DIR/agents"

  # Skip if no source agents exist
  [ -d "$source_agents" ] || return 0

  mkdir -p "$provider_agents"

  echo "[$provider_name] Syncing agents → $root_dir/$agents_dir/"

  # Build set of expected filenames for stale detection
  local -a expected_names=()

  # Create/update agent files
  for agent_path in "$source_agents"/*.md; do
    [ -f "$agent_path" ] || continue
    local agent_basename
    agent_basename="$(basename "$agent_path" .md)"

    # Determine target name based on provider suffix
    local link_name
    if [ "$agent_suffix" = ".md" ]; then
      link_name="${agent_basename}.md"
    else
      link_name="${agent_basename}${agent_suffix}"
    fi

    expected_names+=("$link_name")
    local link_path="$provider_agents/$link_name"

    if [ "$provider_name" = "claude" ]; then
      # Claude: copy with model frontmatter transform
      local expected_content
      expected_content="$(filter_claude_model < "$agent_path")"

      if [ -f "$link_path" ] && [ ! -L "$link_path" ]; then
        local existing_content
        existing_content="$(cat "$link_path")"
        if [ "$existing_content" = "$expected_content" ]; then
          log_skip "$root_dir/$agents_dir/$link_name"
          continue
        fi
      fi

      # Remove stale symlink if present
      [ -L "$link_path" ] && rm "$link_path"

      echo "$expected_content" > "$link_path"
      log_create "$root_dir/$agents_dir/$link_name (copied)"
    else
      # Other providers: symlink
      local rel_target="../../.agents/agents/$(basename "$agent_path")"

      if [ -L "$link_path" ]; then
        local current_target
        current_target="$(readlink "$link_path")"
        if [ "$current_target" = "$rel_target" ]; then
          log_skip "$root_dir/$agents_dir/$link_name"
          continue
        fi
        rm "$link_path"
      elif [ -e "$link_path" ]; then
        log_warn "$root_dir/$agents_dir/$link_name"
        continue
      fi

      ln -s "$rel_target" "$link_path"
      log_create "$root_dir/$agents_dir/$link_name → $rel_target"
    fi
  done

  # Remove stale entries
  for link_path in "$provider_agents"/*; do
    [ -e "$link_path" ] || [ -L "$link_path" ] || continue
    local entry_name
    entry_name="$(basename "$link_path")"

    if [ "$provider_name" = "claude" ]; then
      # For claude: remove stale regular files or symlinks that we manage
      # Only remove .md files that match the naming pattern from source
      [[ "$entry_name" == *.md ]] || continue
      [ -L "$link_path" ] || [ -f "$link_path" ] || continue
    else
      # For other providers: only remove symlinks
      [ -L "$link_path" ] || continue
    fi

    # Check if this entry is in the expected set
    local is_expected=false
    for expected in "${expected_names[@]}"; do
      if [ "$entry_name" = "$expected" ]; then
        is_expected=true
        break
      fi
    done

    if ! $is_expected; then
      # Verify it corresponds to a source name pattern before removing
      local source_name
      if [ "$agent_suffix" = ".agent.md" ]; then
        source_name="$(basename "$entry_name" .agent.md).md"
      else
        source_name="$entry_name"
      fi

      # Only remove if source no longer exists (guards against manually-created files)
      if [ ! -f "$source_agents/$source_name" ]; then
        rm "$link_path"
        log_remove "$root_dir/$agents_dir/$entry_name"
      fi
    fi
  done
}

# ─── Main ────────────────────────────────────────────────────────────────────
echo "Syncing .agents/ → provider folders..."
echo ""

for entry in "${PROVIDERS[@]}"; do
  IFS='|' read -r name root_dir skills_dir agents_dir agent_suffix <<< "$entry"
  sync_skills "$name" "$root_dir" "$skills_dir"
  sync_agents "$name" "$root_dir" "$agents_dir" "$agent_suffix"
  echo ""
done

echo "Done: $created created, $skipped up to date, $removed removed, $warned warnings"
