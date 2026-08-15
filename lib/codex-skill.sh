#!/usr/bin/env bash
# The Codex-side skill surface, shared by install.sh, uninstall.sh and
# scripts/repo/resync-installed.sh.
#
# WHY THIS FILE EXISTS: install.sh writes the Codex surface, uninstall.sh removes
# it, and resync-installed.sh (contract C7) re-derives it to detect drift. Three
# writers of the same on-disk shape would drift, and the drift is invisible: a
# resync that renders the file even slightly differently from the installer
# reports permanent phantom drift on every run, forever. Same rationale as
# lib/render.sh and lib/metadata.sh — one emitter, three callers.
#
# ---------------------------------------------------------------------------
# THE TARGET FORMAT, AND HOW IT WAS CONFIRMED (repo#285)
# ---------------------------------------------------------------------------
# OpenAI Codex CLI discovers skills from a REPO-SCOPED directory, using the open
# Agent Skills format (https://agentskills.io) that Anthropic released and Codex
# adopted. Verified 2026-08-13 against the upstream docs, not inferred:
#
#   - https://developers.openai.com/codex/skills  ("Where Codex loads local
#     skills"): Codex scans `.agents/skills` in every directory from the current
#     working directory up to the repository root, plus `$HOME/.agents/skills`
#     (user), `/etc/codex/skills` (admin), and skills bundled with Codex.
#     Symlinked skill folders are supported and followed.
#   - A skill is a DIRECTORY containing `SKILL.md`, optionally alongside
#     `scripts/`, `references/`, and `assets/`.
#   - https://agentskills.io/specification: `SKILL.md` is YAML frontmatter plus a
#     Markdown body. `name` and `description` are the only REQUIRED keys, and
#     `name` is constrained: 1-64 chars, lowercase `a-z0-9` and hyphens only, no
#     leading/trailing/consecutive hyphens, and it MUST match the parent
#     directory name.
#
# So there is no need to invent an interim format: the repo-scoped target is
# `$REPO_ROOT/.agents/skills/<name>/SKILL.md`, and Codex picks it up with no
# config file, no manifest, and no write outside the consumer repo.
#
# THE ONE ADAPTATION THIS FORCES. `skills/repo/SKILL.md`'s own frontmatter is
# `name: "Repo Skills"`, which the spec above rejects (uppercase and a space).
# skills/README.md classifies `name` as runtime-neutral in MEANING, and it is —
# but this repo's literal VALUE is not portable, so the Codex copy is rendered
# with `name: repo`, matching its parent directory. The Claude-Code-specific
# `type` / `user-invocable` keys (see skills/README.md § "Frontmatter field
# reference") are dropped rather than passed through: they name Claude Code's own
# two install-target surfaces and mean nothing to Codex's discovery. `domain` is
# carried forward under the spec's `metadata` map, where arbitrary string keys
# are explicitly allowed, instead of as a bare unknown top-level key.
#
# WHAT IS *NOT* DUPLICATED. The body of the Codex `SKILL.md` is the canonical
# `skills/repo/SKILL.md` body, byte-for-byte after rendering — not a second copy
# of the workflow written for Codex. The per-verb procedures are the same
# `commands/repo/<verb>.md` files Claude Code registers as `/repo:<verb>`,
# copied unchanged into the skill's `references/` directory (the spec's own
# convention for bundled documentation). The only generated content is the
# frontmatter and a short pointer section naming those reference files — thin
# runtime registration around one canonical procedure body, which is exactly the
# shape skills/README.md § "What a Codex adapter should replicate" fixes.
#
# Sourcing contract: define nothing else, assume nothing about the caller's shell
# options, touch no global except the CODEX_* names below. `codex_skill_render`
# additionally requires lib/render.sh to have been sourced (it pipes the body
# through `render`); the path/marker helpers do not.

# Repo-scoped Codex skill discovery root, relative to the consumer repo root.
CODEX_SKILLS_ROOT_REL=".agents/skills"

# This package's skill name. Doubles as the directory name because the Agent
# Skills spec requires `name` to match the parent directory.
CODEX_SKILL_SLUG="repo"

# The installed skill directory, relative to the consumer repo root.
CODEX_SKILL_REL="$CODEX_SKILLS_ROOT_REL/$CODEX_SKILL_SLUG"

# Where the per-verb command procedures land inside that directory. Read only by
# the files that source this one, like every constant here.
# shellcheck disable=SC2034
CODEX_REFERENCES_REL="$CODEX_SKILL_REL/references"

# Ownership token. `.agents/skills/` is a SHARED, standardized namespace — other
# tools, and the consumer themselves, legitimately keep skills there — so both
# the installer and the uninstaller prove a directory is ours before writing over
# or deleting it. A hand-authored `.agents/skills/repo/` (no marker) is left
# strictly alone rather than clobbered.
CODEX_MANAGED_MARKER='<!-- repo-skills:codex-managed -->'

# codex_skill_frontmatter_value <file> <key>
# Echo a scalar value from <file>'s leading YAML frontmatter block, with
# surrounding double quotes stripped; echo nothing when the file has no
# frontmatter or the key is absent. Deliberately minimal: this repo's SKILL.md
# frontmatter is a flat five-key block of plain/double-quoted scalars (pinned by
# skills/README.md), and a real YAML parser is not a dependency an installer that
# must run anywhere can take.
codex_skill_frontmatter_value() {
  [[ -f "$1" ]] || return 0
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    {
      idx = index($0, ":")
      if (idx > 0) {
        k = substr($0, 1, idx - 1)
        v = substr($0, idx + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (k == key) {
          if (length(v) > 1 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"")
            v = substr(v, 2, length(v) - 2)
          print v
          exit
        }
      }
    }
  ' "$1"
}

# codex_skill_body <file>
# Echo everything after the leading frontmatter block. A file with no frontmatter
# is echoed whole rather than swallowed.
codex_skill_body() {
  [[ -f "$1" ]] || return 0
  awk '
    NR == 1 && $0 != "---" { print; nofm = 1; next }
    nofm { print; next }
    NR == 1 { infm = 1; next }
    infm && $0 == "---" { infm = 0; started = 1; next }
    infm { next }
    started { print }
  ' "$1"
}

# codex_skill_render <src-skill-md> <commands-newline-list>
# Write the installed Codex `SKILL.md` to stdout. Returns 1 (writing nothing)
# when the source carries no `description`, since that key is REQUIRED by the
# spec and a skill without one is silently useless rather than loudly broken.
#
# Requires lib/render.sh: the canonical body is piped through `render` so the
# Codex copy substitutes the same template variables as the Claude copy.
codex_skill_render() {
  local src="$1" commands="${2:-}" desc domain cmd
  desc="$(codex_skill_frontmatter_value "$src" description)"
  [[ -n "$desc" ]] || return 1
  domain="$(codex_skill_frontmatter_value "$src" domain)"

  # Escape for a YAML double-quoted scalar (backslash first, then the quote).
  desc="${desc//\\/\\\\}"
  desc="${desc//\"/\\\"}"

  printf -- '---\n'
  printf 'name: %s\n' "$CODEX_SKILL_SLUG"
  printf 'description: "%s"\n' "$desc"
  if [[ -n "$domain" ]]; then
    printf 'metadata:\n'
    printf '  domain: "%s"\n' "$domain"
  fi
  printf -- '---\n'
  printf '\n%s\n' "$CODEX_MANAGED_MARKER"
  printf '%s\n' '<!-- Generated by Repo Skills install.sh from skills/repo/SKILL.md. Edit the source, not this file. -->'

  codex_skill_body "$src" | render

  if [[ -n "$commands" ]]; then
    printf '\n## Command procedures\n'
    printf '\n%s\n' 'Every `[[verb]]` in the Commands table above has its full procedure in a'
    printf '%s\n' 'file next to this one, under `references/`. Read the one the task needs —'
    printf '%s\n' 'these are the same files Claude Code registers as `/repo:<verb>` slash'
    printf '%s\n' 'commands, copied here unchanged, so the two runtimes run one procedure.'
    printf '\n'
    while IFS= read -r cmd; do
      [[ -n "$cmd" ]] || continue
      printf -- '- `references/%s.md`\n' "$cmd"
    done <<<"$commands"
  fi
}

# codex_skill_is_managed <skill-md-path>
# True when the file exists and carries the ownership marker this package writes.
codex_skill_is_managed() {
  [[ -f "$1" ]] && grep -qF "$CODEX_MANAGED_MARKER" "$1"
}
