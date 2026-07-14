# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Memex is a context-aware documentation system for Claude Code. A `UserPromptSubmit` hook extracts search terms from the user's prompt, runs a lexical (ripgrep/grep) search over the project's docs, ranks the matches, and injects the most relevant sections back into the conversation under a token budget. An optional `docs/GLOSSARY.md` can pin specific docs to keywords, but the engine works with no glossary at all.

## Development

This is a bash-only project. No build step required.

| Task | Command |
|------|---------|
| Install to a project | `./install.sh /path/to/project` |
| Install (force, no prompts) | `./install.sh -f /path/to/project` |
| Install without doc migration | `./install.sh --no-migration /path/to/project` |
| Install with separate worktree | `./install.sh /config/path -w /worktree/path` |

### Testing Hooks Locally

After installing to a project, test hooks manually:

```bash
# Test context-enricher (UserPromptSubmit hook) — CC sends `.prompt`
echo '{"prompt": "tell me about the database schema", "session_id": "test"}' | .claude/hooks/context-enricher.sh

# Test session-start (SessionStart hook)
.claude/hooks/session-start.sh

# Test validate-docs (PostToolUse hook)
echo '{"tool_name": "Write", "tool_input": {"file_path": "docs/test.md"}}' | .claude/hooks/validate-docs.sh
```

## Architecture

```
memex/
├── install.sh              # Installer (entry point)
├── .claude/
│   ├── hooks/              # Hook scripts (also run as ${CLAUDE_PLUGIN_ROOT}/.claude/hooks)
│   │   ├── context-enricher.sh   # Core: lexical retrieval + ranked doc injection
│   │   ├── session-start.sh      # Shows git status, available docs
│   │   ├── session-end.sh        # Archives working documents (opt-in)
│   │   ├── validate-docs.sh      # Size limits, glossary reminders
│   │   └── telemetry.sh          # OpenTelemetry helper (sourced by others)
│   └── skills/             # Skills (copied to target projects)
├── skills/                 # Skill source files
│   ├── memex-docs/         # Documentation writing guidelines
│   └── migrate-docs/       # Legacy doc migration helper
└── templates/              # Template files for new installations
    ├── CLAUDE.md.template
    ├── GLOSSARY.md.template
    └── CONTRIBUTING.md.template
```

### Hook Flow

1. **SessionStart** → `session-start.sh`: Read-only banner — shows git status and available docs. Does not auto-update or `git pull` (use `/plugin update` or `install.sh`).
2. **UserPromptSubmit** → `context-enricher.sh`: Extracts terms from the prompt, lexically searches the project, ranks and injects the densest matching sections under a token budget (excludes `docs/archive/`, `.claude/`, and `GLOSSARY.md` itself).
3. **PostToolUse** → `validate-docs.sh`: Warns (advisory only, never blocks) when doc edits exceed size limits.
4. **SessionEnd** → `session-end.sh`: Archives `docs/working/` files — opt-in via `MEMEX_ARCHIVE_WORKING=TRUE`.

### context-enricher.sh Internals

The core logic lives in `context-enricher.sh`:
- **Term extraction**: identifier-shaped tokens (camelCase / snake_case / dotted) kept whole, plus stopword-filtered plain words; deduped, longest-first, capped at `MAX_TERMS` (scan bounded by `MEMEX_SCAN_TOKEN_CAP`, default 200).
- **Search**: one `--fixed-strings --ignore-case` pass per term via `rg` (falls back to `grep -rIn`), from `PROJECT_ROOT`, honoring exclude globs.
- **Ranking**: densest-window over match line numbers per file; section-level extraction via `extract_md_section()` (fence-aware) with an `extract_line_window()` fallback.
- **Budget**: `MAX_TOTAL_TOKENS` (default 10k) cap; per-section cap `MAX_SECTION_LINES`.
- **Dedup**: per-session `injected` ledger under a secured temp dir keyed on `session_id`.
- **Output**: JSON `additionalContext` (jq-escaped), with a raw-stdout fallback.

Optional keyword pins live in `docs/GLOSSARY.md` as `- **keyword** -> \`path\`` bullets; a whole-word prompt match boosts that path into the candidate set.

## Key Constraints

1. **Bash 3.x compatibility** - No associative arrays (macOS ships bash 3.x)
2. **jq dependency** - Required for JSON parsing in hooks
3. **Token budget** - Default 10k tokens, configurable via `MAX_TOTAL_TOKENS`
4. **Size limits** - Files: 800 lines, Sections: 150 lines
5. **Archive exclusion** - `docs/archive/` is never loaded by context-enricher

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `MAX_TOTAL_TOKENS` | Token budget for injected context (default 10000) |
| `MEMEX_SCAN_TOKEN_CAP` | Max prompt tokens inspected during term extraction (default 200) |
| `MEMEX_ARCHIVE_WORKING=TRUE` | Opt in to archiving+clearing `docs/working/` on SessionEnd |
| `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `OTEL_EXPORTER_OTLP_ENDPOINT` | Enable OpenTelemetry emission to your own collector (no-op otherwise) |

`session-start.sh` is read-only and never pulls/updates; update via `/plugin update` or `install.sh`.

## File Naming Conventions

When documentation exceeds limits, split using:
```
CATEGORY_SUBCATEGORY.md
```
Example: `DATABASE_SCHEMA.md`, `DATABASE_QUERIES.md`
