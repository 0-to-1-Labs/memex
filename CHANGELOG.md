# Changelog

All notable changes to Memex are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/); versioning is
[semantic](https://semver.org/).

## [2.0.0] - 2026-09-30

The lexical retrieval engine replaces the keyword map. This release also
closes the 2026-09 audit: a fast single-pass search, safe glossary pins and
archiving, working `#anchor` pins, a PostToolUse output that Claude can read,
and telemetry that sends counts only.

### Added
- **`path#anchor` glossary pins select that section.** The anchor is matched
  against heading slugs (lowercase, punctuation removed, spaces to hyphens);
  the whole file is used when no heading matches.
- **Default search scope `docs/` plus root `*.md`.** Set
  `MEMEX_SEARCH_SCOPE=repo` to search every non-hidden, non-ignored file.
- `tests/run-tests.sh`: a dependency-free bash test runner that builds
  throwaway projects and runs every hook against them (anchor pins, path
  containment, fences, locale, archiving, a 3,000-file timing check).
- Explicit `timeout` values for every hook in `hooks/hooks.json` (10 s), and an
  anchored `^(Write|Edit)$` PostToolUse matcher.

### Fixed
- **UserPromptSubmit latency.** The per-line bash loop over search hits (28 s
  on a 440-file repo, minutes on 3,000 files) is gone: one grep pass per term,
  one sort and one awk pass for ranking. 440 files: 0.3 s; 3,000 files: 0.4 s
  (0.8 s with eight terms).
- **Stopwords became search terms on macOS.** Under a UTF-8 locale bash 3.2's
  `[A-Z]` matched lowercase letters, so every word looked like an identifier.
  The hooks now run under `LC_ALL=C` and use POSIX classes.
- **Glossary pins could read outside the project.** Pins with `..`, absolute
  paths, or symlinks are rejected; every file read is resolved with `pwd -P`
  and must sit under the project root. Symlinks are never read.
- **`validate-docs.sh` output never reached Claude.** PostToolUse stdout goes
  to the debug log only; the hook now returns JSON
  `hookSpecificOutput.additionalContext`.
- **Archive overwrite and data loss.** Two sessions ending in the same second
  shared one archive name. Names now include the session id, pid, and a random
  suffix; archives live under `~/.memex/archives/<project>/`; the archive is
  written to a temp name and renamed only after its listing matches the files
  on disk; `/clear` and `/resume` never archive.
- **Hidden and gitignored files were searched** by the grep fallback (`.env`
  contents were injected). The file list now comes from
  `git ls-files --exclude-standard` (or `find` outside git), skipping hidden
  files, `docs/archive/`, `GLOSSARY.md`, symlinks, and key/secret file names.
  `rg` is no longer used or required.
- **Telemetry stalled prompts** when the collector was down: the background
  `curl` kept the hook's stdout open. The send is now fully detached with a
  2 s cap. Auth headers go through a private file instead of the process list.
- **Section selection** picks the section that owns the most matches (a parent
  heading no longer out-counts its own subsections); fences close only on the
  same character with at least the opening length, so a ```` block containing a
  ``` block does not turn a code comment into a heading (enricher and
  validator).
- File names containing `:` are handled (`grep --null`).
- Injected excerpts are labeled as untrusted reference data, wrapped in
  `<file path=... lines=...>` blocks, and any `</auto-context>` inside a file
  is neutralized.
- Token budget is estimated as bytes/4 and now actually binds
  (`MAX_TOTAL_TOKENS`, default 10000 per prompt).
- Glossary reminder is once per session (keyed by `session_id`), not once per
  machine, and the marker lives in the owner-checked temp dir.
- Session dedup ledger is cleared on `/clear` and compaction; stale session
  caches are removed after 7 days.
- `install.sh`: backs up `settings.json` before merging, never overwrites a
  settings file it cannot parse, keeps installing templates, and reports what
  it skipped. Migration skips hidden directories (`.claude/`, `.github/`,
  `.venv/`) and build output, so re-runs no longer ingest installed skills.
- Telemetry JSON is built with `jq`; a quote in a path or project name cannot
  break a batch.

### Changed
- **Telemetry sends counts only**: no search terms, file paths, project name,
  or hostname. `memex.term.matched` (per-term) became `memex.terms.matched`
  (a count); `memex.cache.*` and `memex.keyword.matched` were removed.
- **SessionStart banner** is silent in projects without `docs/`, silent on
  `/clear` and compaction, and one or two lines otherwise. Git status is no
  longer repeated (Claude Code already provides it).
- Removed the shipped `docs/` tree (stale copies of old README/SKILL files
  and a `.content-hashes` file with a home-directory path). Templates stay.
- Repository moved to `github.com/0-to-1-Labs/memex`.
- Version 2.0.0 in `plugin.json`, the skills, the README, and telemetry.
- Stopped tracking the dev-only `.claude/settings.json` (plugin consumers use
  `hooks/hooks.json`; it double-fired hooks if the repo was opened as a project).
- Removed the dead duplicate `.claude/skills/` copy (`skills/` is canonical).
- Reconciled README / CLAUDE.md / CONTRIBUTING / skills / command with the
  lexical engine and removed references to the deleted `scan-docs.sh` and to
  session-start auto-update/auto-pull (session-start is read-only).

## [1.0.1]

- Term extraction uses builtin `case` tests and bounds the scan
  (`MEMEX_SCAN_TOKEN_CAP`, default 200), so a long prompt no longer stalls the
  hook.
- Fixed the macOS data-loss bug in session-end archiving (`tar --exclude='.*'`
  produced an empty archive on bsdtar, then the working files were deleted).
- The retriever no longer injects its own hooks (`.claude/`) or `GLOSSARY.md`.
- Section extraction ignores `#` lines inside fenced code blocks.
- Glossary pin matching is word-boundary and reads the path from the last
  backtick pair.

## [1.0.0]

First release packaged as a Claude Code marketplace plugin, alongside the
existing installer script.

### Added
- **Marketplace plugin packaging** — `.claude-plugin/plugin.json` and
  `hooks/hooks.json` so Memex can be installed via `/plugin install` and
  updated via `/plugin update`.
- **`/memex-init` command** — scaffolds the `docs/` tree, `GLOSSARY.md`,
  `CONTRIBUTING.md`, and the `CLAUDE.md` section for plugin users (idempotent).
- **Runtime keyword mappings** — the context-enricher read keyword →
  doc mappings from `docs/GLOSSARY.md` at runtime (replaced by lexical
  retrieval with optional pins in 2.0.0).
- `version` frontmatter on the `memex-docs` and `migrate-docs` skills.

### Changed
- **Hooks resolve the project root at runtime** via `$CLAUDE_PROJECT_DIR`
  (falling back to the working directory) instead of an install-time
  `{{PROJECT_ROOT}}` substitution. The same scripts work in both plugin
  and installer modes; the installer no longer rewrites the hooks.
- `skills/` is the single canonical source for bundled skills; the installer
  no longer copies from a second `.claude/skills/` location.
