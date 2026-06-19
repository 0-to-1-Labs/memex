# Changelog

All notable changes to Memex are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); versioning is
[semantic](https://semver.org/).

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
