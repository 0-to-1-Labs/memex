# Changelog

All notable changes to Memex are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); versioning is
[semantic](https://semver.org/).

## [Unreleased]

Pre-publish review pass: ship the lexical retrieval engine, fix a macOS
data-loss bug, and reconcile docs with the current implementation.

### Fixed
- **Data loss on macOS (session-end archiving).** `tar --exclude='.*' .` produced
  an empty archive on bsdtar (the `.*` pattern matched the `.` argument), yet the
  hook still deleted `docs/working/`. Now archives an explicit file list and only
  deletes when the archive is verified to contain the files.
- **Latency on long prompts.** Term extraction spawned `grep` subprocesses per
  token with no cap, so a long prompt could stall the `UserPromptSubmit` hook for
  ~25s. Now uses builtin `case` tests and bounds the scan (`MEMEX_SCAN_TOKEN_CAP`,
  default 200) — a 6k-token prompt runs in <1s.
- **Self-ingestion.** The retriever no longer injects its own hooks (`.claude/`)
  or `GLOSSARY.md` as "context".
- **Code-fence headings.** Section extraction now ignores `#` lines inside
  fenced code blocks, so excerpts no longer snap to a code comment.
- **Glossary pins.** Keyword matching is now word-boundary (`api` no longer pins
  on "rapid"), and the path is read from the last backtick pair (a backticked
  keyword no longer corrupts the path).

### Changed
- Stopped tracking the dev-only `.claude/settings.json` (plugin consumers use
  `hooks/hooks.json`; it double-fired hooks if the repo was opened as a project).
- Removed the dead duplicate `.claude/skills/` copy (`skills/` is canonical).
- Reconciled README / CLAUDE.md / CONTRIBUTING with the lexical engine and
  removed references to the deleted `scan-docs.sh` and to session-start
  auto-update/auto-pull (session-start is read-only).

## [1.0.0]

First release packaged as a Claude Code marketplace plugin, alongside the
existing installer script.

### Added
- **Marketplace plugin packaging** — `.claude-plugin/plugin.json` and
  `hooks/hooks.json` so Memex can be installed via `/plugin install` and
  updated via `/plugin update`.
- **`/memex-init` command** — scaffolds the `docs/` tree, `GLOSSARY.md`,
  `CONTRIBUTING.md`, and the `CLAUDE.md` section for plugin users (idempotent).
- **Runtime keyword mappings** — the context-enricher now reads keyword →
  doc mappings from `docs/GLOSSARY.md` at runtime. Customization lives in a
  single source of truth and no longer requires editing the hook script,
  which is what allows distribution as a plugin. Built-in defaults remain as
  a fallback when no `GLOSSARY.md` exists.
- `version` frontmatter on the `memex-docs` and `migrate-docs` skills.

### Changed
- **Hooks resolve the project root at runtime** via `$CLAUDE_PROJECT_DIR`
  (falling back to the working directory) instead of an install-time
  `{{PROJECT_ROOT}}` substitution. The same scripts now work in both plugin
  and installer modes; the installer no longer rewrites the hooks.
- **Project auto-pull is now opt-in** (`MEMEX_AUTO_PULL=TRUE`). Silently
  `git pull`-ing the user's repo on session start was surprising, especially
  for a distributed plugin, so it is disabled by default.
- `skills/` is the single canonical source for bundled skills; the installer
  no longer copies from a second `.claude/skills/` location.

### Plugin behavior
- The Memex self-update path (git pull + reinstall on session start) runs in
  **installer mode only**. Under the plugin, `$CLAUDE_PLUGIN_ROOT` is set and
  updates are delegated to `/plugin update`.
