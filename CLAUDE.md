# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Memex is a context-aware documentation system for Claude Code. A `UserPromptSubmit` hook extracts search terms from the user's prompt, runs a lexical (grep) search over the project's docs (`docs/` plus root `*.md` by default), ranks the matches, and injects the most relevant sections back into the conversation under a token budget. An optional `docs/GLOSSARY.md` can pin specific docs (or `#anchor` sections) to keywords, but the engine works with no glossary at all.

## Development

This is a bash-only project. No build step required.

| Task | Command |
|------|---------|
| Run the tests | `bash tests/run-tests.sh` |
| Lint | `bash -n .claude/hooks/*.sh install.sh && shellcheck .claude/hooks/*.sh install.sh` |
| Validate the plugin | `claude plugin validate .` |
| Install to a project | `./install.sh /path/to/project` |
| Install (force, no prompts) | `./install.sh -f /path/to/project` |
| Install without doc migration | `./install.sh --no-migration /path/to/project` |
| Install with separate worktree | `./install.sh /config/path -w /worktree/path` |

### Testing Hooks Locally

Never point `CLAUDE_PROJECT_DIR` at a real project (`session-end.sh` deletes `docs/working/` when opted in). Unset `OTEL_*` first.

```bash
export CLAUDE_PROJECT_DIR=/tmp/test-project CLAUDE_PLUGIN_ROOT=$PWD

# context-enricher (UserPromptSubmit hook) — CC sends `.prompt`
echo '{"prompt": "tell me about the database schema", "session_id": "test"}' | bash .claude/hooks/context-enricher.sh

# session-start (SessionStart hook)
echo '{"session_id": "test", "source": "startup"}' | bash .claude/hooks/session-start.sh

# validate-docs (PostToolUse hook)
echo '{"session_id": "test", "tool_name": "Write", "tool_input": {"file_path": "/tmp/test-project/docs/test.md"}}' | bash .claude/hooks/validate-docs.sh
```

## Architecture

```
memex/
├── install.sh              # Installer (entry point, installer mode)
├── hooks/hooks.json        # Hook registration + timeouts (plugin mode)
├── .claude/
│   └── hooks/              # Hook scripts (also run as ${CLAUDE_PLUGIN_ROOT}/.claude/hooks)
│       ├── context-enricher.sh   # Core: lexical retrieval + ranked doc injection
│       ├── session-start.sh      # Short status, session-cache housekeeping
│       ├── session-end.sh        # Archives working documents (opt-in)
│       ├── validate-docs.sh      # Size limits, glossary reminders (JSON output)
│       └── telemetry.sh          # OpenTelemetry helper (sourced by others)
├── commands/memex-init.md  # /memex-init scaffold
├── skills/                 # Skill source files
│   ├── memex-docs/         # Documentation writing guidelines
│   └── migrate-docs/       # Legacy doc migration helper
├── templates/              # Template files for new installations
│   ├── CLAUDE.md.template
│   ├── GLOSSARY.md.template
│   └── CONTRIBUTING.md.template
└── tests/run-tests.sh      # Dependency-free hook tests
```

### Hook Flow

1. **SessionStart** → `session-start.sh`: silent without `docs/`; otherwise a one-line status. Clears the session's injection ledger on `clear`/`compact`. Does not auto-update or `git pull`.
2. **UserPromptSubmit** → `context-enricher.sh`: extracts terms, builds the file list once (`git ls-files --exclude-standard` or `find`), one grep pass per term, ranks and injects the densest matching sections under a byte-based token budget.
3. **PostToolUse** (`^(Write|Edit)$`) → `validate-docs.sh`: returns size warnings as JSON `hookSpecificOutput.additionalContext` (advisory only, never blocks).
4. **SessionEnd** → `session-end.sh`: archives `docs/working/` — opt-in via `MEMEX_ARCHIVE_WORKING=TRUE`; unique archive names, verified before deleting; skipped on `clear`/`resume`.

### context-enricher.sh Internals

- **Locale**: `LC_ALL=C` (bash 3.2 `[A-Z]` is wrong under UTF-8 on macOS).
- **Term extraction**: identifier-shaped tokens (camelCase / snake_case / dotted) kept whole, plus stopword-filtered plain words; deduped, longest-first, capped at `MAX_TERMS` (scan bounded by `MEMEX_SCAN_TOKEN_CAP`, default 200).
- **File list**: one pass; hidden files, gitignored files, `docs/archive/`, `GLOSSARY.md`, symlinks, key/secret file names and build dirs are excluded. Scope `docs` (default) or `repo` via `MEMEX_SEARCH_SCOPE`.
- **Search**: `xargs -0 grep -HIn --null --fixed-strings --ignore-case` per term over the list; bounded per file and per term.
- **Ranking**: one `sort` + one `awk` pass emits score, distinct terms, and the sorted match lines per file.
- **Extraction**: markdown → the section that owns the most match lines (fence-aware; `#anchor` pins select a section by heading slug); other files → densest line window.
- **Containment**: `path_in_project` rejects `..`, absolute paths and symlinks, and checks the physical path prefix.
- **Budget**: `MAX_TOTAL_TOKENS` (default 10k, bytes/4) per prompt; per-section cap `MAX_SECTION_LINES`.
- **Dedup**: per-session `injected` ledger under a secured temp dir keyed on `session_id`.
- **Output**: JSON `additionalContext` (jq-escaped) with excerpts in `<file path lines>` blocks labeled untrusted; a raw-stdout fallback.

## Key Constraints

1. **Bash 3.2 compatibility** - No associative arrays; must also run on GNU tools
2. **jq dependency** - Required for JSON parsing in hooks
3. **Token budget** - Default 10k tokens (bytes/4), configurable via `MAX_TOTAL_TOKENS`
4. **Size limits** - Files: 800 lines, Sections: 150 lines
5. **Never read outside the project** - every file read passes `path_in_project`
6. **Telemetry sends counts only** - no prompt words, paths, project name, or hostname

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `MAX_TOTAL_TOKENS` | Per-prompt token budget for injected context (default 10000, bytes/4) |
| `MEMEX_SEARCH_SCOPE` | `docs` (default) or `repo` |
| `MEMEX_SCAN_TOKEN_CAP` | Max prompt tokens inspected during term extraction (default 200) |
| `MEMEX_ARCHIVE_WORKING=TRUE` | Opt in to archiving+clearing `docs/working/` on SessionEnd |
| `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `OTEL_EXPORTER_OTLP_ENDPOINT` | Enable OpenTelemetry emission to your own collector (no-op otherwise) |

`session-start.sh` is read-only and never pulls/updates; update via `/plugin update` or `install.sh`.

## Release checklist

Bump the version in `.claude-plugin/plugin.json`, both `skills/*/SKILL.md` frontmatters, `MEMEX_SERVICE_VERSION` in `telemetry.sh`, the README "Resource Attributes" section, and add a CHANGELOG entry.
