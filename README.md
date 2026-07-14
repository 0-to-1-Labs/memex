![Memex Banner](memex-banner.png)

# Memex

A context-aware documentation system for Claude Code. When you ask a question, Memex automatically injects relevant documentation into the conversation based on keywords in your prompt.

Named after Vannevar Bush's 1945 concept of a "memory extender" - a device that stores and retrieves knowledge through associative trails.

## What It Does

Memex uses Claude Code hooks to:

1. **Auto-inject documentation** - When your prompt contains keywords like "database", "api", or "deploy", the matching docs get loaded into context automatically
2. **Section-level loading** - Load specific sections via anchors (`DATABASE.md#schema`) instead of entire files
3. **Token budget awareness** - Stops loading docs when approaching context limits (~10k tokens)
4. **Session deduplication** - Tracks loaded docs per session to avoid re-injecting the same content
5. **Track session state** - Shows git status and available docs when you start a session
6. **Validate docs** - Warns when files exceed 800 lines or sections exceed 150 lines
7. **Archive working notes** - Cleans up temporary working documents at session end
8. **Auto-update** - Checks for memex updates on session start and installs them automatically
9. **Migrate existing docs** - Discovers, deduplicates, and organizes documentation during install

## Installation

Memex ships two ways. Both use the same hooks — pick whichever fits your workflow.

### Option A: Plugin (recommended)

Install from a marketplace and let Claude Code manage updates:

```text
/plugin marketplace add <your-marketplace>
/plugin install memex
```

Then scaffold the docs structure in your project once:

```text
/memex-init
```

The plugin registers the hooks automatically (no edits to your project's
`settings.json`), and `/plugin update memex` handles upgrades.

### Option B: Installer script

Copies the hooks into your project's `.claude/` and self-updates on session start:

```bash
# Clone the repo
git clone https://github.com/johnpsasser/memex.git

# Run the installer from your project root
cd your-project
/path/to/memex/install.sh
```

### Installer Options

| Option | Description |
|--------|-------------|
| `-f, --force` | Skip confirmation prompts |
| `-w, --worktree PATH` | Specify git worktree path for docs/ |
| `--no-migration` | Skip automatic documentation migration |

### What the Installer Does

1. Creates `.claude/hooks/` with all hook scripts
2. Creates `.claude/settings.json` with hook configuration
3. Creates template documentation files in `docs/`
4. Sets up `docs/working/` for temporary notes
5. **Migrates existing docs** - discovers `.md` files, deduplicates by content hash, archives originals to `docs/archive/`
6. **Enables auto-updates** - stores memex source path for automatic updates on session start

### Template Variables

Templates use variable substitution during installation:

| Variable | Replaced With |
|----------|---------------|
| `{{PROJECT_NAME}}` | Directory name of the project |
| `{{DATE}}` | Installation date (YYYY-MM-DD) |

> Hooks no longer need a `{{PROJECT_ROOT}}` substitution — they resolve the
> project root at runtime via `$CLAUDE_PROJECT_DIR`, so the same scripts work
> whether installed by the script or loaded as a plugin.

### Backup Behavior

When installing over existing files:

| File | Behavior |
|------|----------|
| `CLAUDE.md` | Appends memex section (idempotent, won't duplicate) |
| `GLOSSARY.md` | Backs up to `GLOSSARY.md.old`, installs fresh template |
| `CONTRIBUTING.md` | Backs up to `CONTRIBUTING.md.old`, installs fresh template |
| Hook scripts | Always overwritten with latest version |
| `settings.json` | Merged (memex hooks added, other settings preserved) |

## How It Works

![Memex Architecture](memex-architecture.png)

The system has four hooks that run at different points:

| Hook | When | What It Does |
|------|------|--------------|
| `session-start.sh` | Session begins | Shows git info, lists available docs (read-only; never pulls or auto-updates) |
| `context-enricher.sh` | You submit a prompt | Extracts search terms, lexically searches your docs, injects the densest matching sections |
| `validate-docs.sh` | After editing `docs/*.md` | Reminds to update GLOSSARY.md (advisory, never blocks) |
| `session-end.sh` | Session ends | Archives `docs/working/` — opt-in via `MEMEX_ARCHIVE_WORKING=TRUE` |

The context-enricher hook is the key piece. It extracts terms from your prompt, searches your docs with ripgrep (grep fallback), ranks the densest matches, and injects the relevant sections as `additionalContext`:

```
<auto-context>
<!-- Memex auto-retrieved the densest matching excerpts from this repo (read-only, lexical). -->
<!-- docs/core/DATABASE.md : lines 1-24 -->
...section content...
</auto-context>
```

Retrieval is automatic and needs no configuration — no keyword map to maintain. It ranks by lexical relevance and only injects the tightest matching section of each doc, under a token budget.

## Customizing retrieval (optional)

You don't have to configure anything. Two optional levers:

- **Glossary pins** — add `docs/GLOSSARY.md` with `- **keyword** -> \`path\`` bullets. When a whole word from a bullet appears in your prompt, that doc is boosted into the candidate set. Purely additive on top of the automatic lexical search.
- **Budget & scope** — `MAX_TOTAL_TOKENS` (default 10000) caps injected context; `MEMEX_SCAN_TOKEN_CAP` (default 200) bounds how much of a long prompt is scanned. `docs/archive/`, `.claude/`, and `GLOSSARY.md` are never injected.

## Documentation Structure

Memex works best with a tiered documentation structure:

```
your-project/
├── CLAUDE.md              # Quick reference (entry point)
├── docs/
│   ├── GLOSSARY.md        # Keyword-to-file mapping
│   ├── CONTRIBUTING.md    # How to use/update docs
│   ├── core/              # Core system docs
│   │   ├── ARCHITECTURE.md
│   │   ├── DATABASE.md
│   │   └── API.md
│   ├── features/          # Feature-specific docs
│   ├── archive/           # Preserved original docs (excluded from loading)
│   └── working/           # Temp files (gitignored)
└── .claude/
    └── hooks/             # Hook scripts (installer mode)
```

GLOSSARY.md is optional: it lets you pin specific docs to keywords, but retrieval works without it — the engine searches your docs directly and injects only the relevant sections.

## Updating

`session-start.sh` is read-only: it shows git status and available docs and **never** fetches, pulls, or executes remote code on session start. To update Memex itself:

- **Plugin install:** `/plugin update memex`
- **Installer mode:** re-run `./install.sh /path/to/project`

## Documentation Migration

During installation, memex automatically discovers and organizes existing documentation.

### What Gets Migrated

| Original Location | Destination | Condition |
|-------------------|-------------|-----------|
| `.md` files outside `docs/` | `docs/core/` | Filenames with ARCHITECTURE, DATABASE, API, SCHEMA, CONFIG |
| `.md` files outside `docs/` | `docs/features/` | Other documentation files |
| README, CHANGELOG, LICENSE | `docs/archive/` only | Project meta-docs (not loaded) |

### Deduplication

Files are hashed (MD5) to detect duplicates. If identical content already exists, the file is skipped.

### Archive Behavior

- Original files are copied (not moved) to `docs/archive/`
- Archive files are never loaded by the context-enricher
- Use archive to reference original content if needed

### Session Archives

Working documents from `docs/working/` are archived at session end:

| Item | Value |
|------|-------|
| Location | `$HOME/.memex/archives/` |
| Format | `session-YYYYMMDD-HHMMSS.tar.gz` |
| Retention | Last 20 archives (older are auto-deleted) |

To restore a session archive:
```bash
tar -xzf ~/.memex/archives/session-20240115-143022.tar.gz -C /tmp/restore/
```

### Skip Migration

```bash
./install.sh --no-migration /path/to/project
```

## The Glossary

The glossary is an index that maps keywords to documentation files. It lets Claude find relevant docs quickly without loading everything:

```markdown
### Database

- **database** -> `docs/core/DATABASE.md` - Database overview
- **schema** -> `docs/core/DATABASE.md#schema` - Table definitions
- **query** -> `docs/core/DATABASE.md#queries` - Query patterns
```

When you add new documentation, add corresponding entries to the glossary.

## Files Included

```
memex/
├── install.sh                    # 1-click installer
├── README.md                     # This file
├── .claude/
│   ├── settings.json             # Hook configuration (template)
│   └── hooks/
│       ├── session-start.sh      # Shows git info at session start
│       ├── session-end.sh        # Archives working docs
│       ├── context-enricher.sh   # Auto-injects docs (the main hook)
│       ├── validate-docs.sh      # Line limit warnings + glossary reminders
│       └── telemetry.sh          # OpenTelemetry export helper
├── skills/
│   ├── memex-docs/
│   │   └── SKILL.md              # Documentation writing guidelines skill
│   └── migrate-docs/
│       └── SKILL.md              # Legacy documentation migration skill
├── templates/
│   ├── CLAUDE.md.template        # Master reference template
│   ├── GLOSSARY.md.template      # Keyword index template
│   └── CONTRIBUTING.md.template  # Contribution guide template
└── examples/
    └── semantic-map.example.md   # Example keyword mappings
```

### Skill: memex-docs

The `memex-docs` skill provides documentation writing guidelines that Claude loads on-demand when editing files in `docs/`. It includes:

- Size limits (800 lines/file, 150 lines/section)
- Token efficiency patterns (tables over paragraphs, anchor links)
- Update vs. add decision guidance
- GLOSSARY.md formatting rules

The skill loads automatically when Claude detects documentation work, keeping guidelines out of context until needed.

### Skill: migrate-docs

The `migrate-docs` skill helps migrate existing markdown documentation into the memex structure. Use it when installing memex in a repo with existing docs:

```
/migrate-docs
```

The skill guides Claude through:
- **Discovery** - Scans for `.md` files outside `docs/`
- **Categorization** - Interactive assignment to `core/`, `features/`, or `working/`
- **Migration** - Uses `git mv` to preserve history
- **Reformatting** - Splits large files, adds anchors, converts to tables
- **Glossary update** - Generates keywords for migrated content

## Requirements

- Claude Code CLI
- bash 3.x+ (macOS default works)
- jq (for parsing hook input JSON)

Install jq if you don't have it:
```bash
# macOS
brew install jq

# Ubuntu/Debian
apt-get install jq
```

## Best Practices

### Document Size Guidelines

Keep documents small enough to load efficiently but comprehensive enough to be useful.

| Level | Max Lines | Target Lines | Rationale |
|-------|-----------|--------------|-----------|
| File | 800 | 400-600 | Fits in context with room for conversation |
| Section | 150 | 50-100 | Section-level loading stays efficient |
| Index/glossary | 1000 | 500-800 | Keyword indexes are naturally larger |

The `validate-docs.sh` hook warns you when files or sections exceed these limits.

**Note:** `GLOSSARY.md` is exempt from the 800-line file limit. Glossaries naturally grow with your project and serve as an index, so larger sizes are expected.

When a document exceeds 800 lines, split it into sub-documents using the naming convention:

```
CATEGORY_SUBCATEGORY.md
```

Examples:
- `DATABASE_SCHEMA.md`, `DATABASE_QUERIES.md`, `DATABASE_MIGRATIONS.md`
- `AGENTS_SUPERVISOR.md`, `AGENTS_RESEARCH.md`, `AGENTS_IMPLEMENTATION.md`

### Token Efficiency

AI agents pay for every token loaded. Write docs that get to the point.

| Format | Use For | Why |
|--------|---------|-----|
| Tables | Reference data, comparisons | Scannable, compact |
| Bullet lists | Steps, options, features | Easy to parse |
| Anchor links | Cross-references | Load sections, not files |
| Code blocks | Examples, paths | Precise, copy-pasteable |

Avoid:
- Long paragraphs when a table works
- Repeating information across files
- Loading entire files when a section suffices

### Keyword Specificity

**Be specific with keywords.** Instead of matching "test" (too common), match "testing" or "jest" or "vitest".

### Anchor Links

**Use anchor links.** Point to specific sections like `DATABASE.md#schema` rather than whole files. This lets agents load only what they need.

### Incremental Growth

**Start small.** You don't need to document everything upfront. Start with CLAUDE.md and GLOSSARY.md, then add specialized docs as your project grows.

**Update the glossary as you go.** The validation hook reminds you, but get in the habit of adding keywords when you add docs.

## OpenTelemetry Support

Memex can export metrics to an OpenTelemetry collector, using the same configuration as Claude Code. When you enable telemetry for Claude Code, Memex automatically starts exporting its own metrics to the same endpoint.

### Enabling Telemetry

Set the same environment variables Claude Code uses:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

That's it. Memex detects these variables and exports metrics via HTTP/JSON to the OTLP endpoint.

### Metrics Exported

| Metric | Type | Description |
|--------|------|-------------|
| `memex.hook.invocations` | Counter | Hook executions by name and outcome |
| `memex.hook.duration_ms` | Gauge | Hook execution time in milliseconds |
| `memex.session.count` | Counter | Sessions started |
| `memex.docs.loaded` | Counter | Documents loaded into context |
| `memex.tokens.injected` | Counter | Tokens injected per prompt |
| `memex.tokens.budget.used` | Gauge | Token budget consumption |
| `memex.tokens.budget.utilization_percent` | Gauge | Percentage of budget used |
| `memex.cache.hit` | Counter | Docs skipped (session deduplication) |
| `memex.cache.miss` | Counter | Docs actually loaded |
| `memex.prompt.no_match` | Counter | Prompts with no keyword matches |
| `memex.validation.warning` | Counter | Doc size limit warnings |
| `memex.doc.edits` | Counter | Documentation file edits |
| `memex.archive.created` | Counter | Session archives created |

### Events Exported

| Event | Description |
|-------|-------------|
| `memex.session.start` | Session started with project name |
| `memex.session.end` | Session ended with files archived count |
| `memex.doc.edited` | Documentation file was modified |
| `memex.validation.warning` | Validation warning details |

### Resource Attributes

All metrics include these resource attributes:

- `service.name`: `memex`
- `service.version`: `1.0.0`
- `host.name`: Hostname
- `os.type`: Operating system
- `process.pid`: Process ID

### Configuration Options

Memex respects these environment variables:

| Variable | Purpose |
|----------|---------|
| `MAX_TOTAL_TOKENS` | Token budget for injected context (default `10000`) |
| `MEMEX_SCAN_TOKEN_CAP` | Max prompt tokens inspected during term extraction (default `200`) |
| `MEMEX_ARCHIVE_WORKING` | Set to `TRUE` to archive+clear `docs/working/` on session end |
| `CLAUDE_CODE_ENABLE_TELEMETRY` | Enable telemetry (must be `1`) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector endpoint |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers (format: `Key=Value,Key2=Value2`) |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Protocol (`grpc`, `http/json`, `http/protobuf`) |

### Example: Local Testing

Run a local OpenTelemetry collector with Docker:

```bash
docker run -p 4318:4318 otel/opentelemetry-collector-contrib:latest
```

Then enable telemetry:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

## How This Came About

This grew out of a need to give Claude Code agents better context without blowing up the token budget. The hook system lets you selectively load documentation based on what the user is actually asking about, rather than dumping everything into the system prompt.

The original implementation was built for a project with ~15 documentation files. Without selective loading, every conversation would start with thousands of tokens of docs that might not be relevant. With Memex, the docs load on-demand based on the conversation.

## License

MIT
