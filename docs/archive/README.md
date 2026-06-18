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

## How It Works

![Memex Architecture](memex-architecture.png)

The system has four hooks that run at different points:

| Hook | When | What It Does |
|------|------|--------------|
| `session-start.sh` | Session begins | Shows git info, lists available docs |
| `context-enricher.sh` | You submit a prompt | Scans for keywords, injects matching docs |
| `validate-docs.sh` | After editing `docs/*.md` | Reminds to update GLOSSARY.md |
| `session-end.sh` | Session ends | Archives working documents |

The context-enricher hook is the key piece. It reads your prompt, looks for keywords, and wraps matching documentation in XML tags that get injected into the conversation:

```xml
<auto-loaded-documentation>
<doc path="docs/core/DATABASE.md">
...documentation content...
</doc>
</auto-loaded-documentation>
```

## Customizing Keywords

Edit `.claude/hooks/context-enricher.sh` to add your own keyword patterns:

```bash
# Full file loading
case "$PROMPT_LOWER" in
    *authentication*|*login*|*oauth*|*jwt*)
        add_doc "features/AUTH.md"
        ;;
esac

# Section-level loading (more efficient!)
case "$PROMPT_LOWER" in
    *"oauth flow"*|*"oauth setup"*)
        add_doc "features/AUTH.md#oauth-flow"  # Only loads that section
        ;;
esac
```

The pattern matching is simple: if any of the keywords appear in the prompt (case-insensitive), the doc gets loaded. With section anchors, only the relevant section is extracted.

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
    ├── settings.json      # Hook configuration
    ├── .memex-source      # Path to memex repo (for auto-updates)
    └── hooks/             # Hook scripts
```

The idea is that GLOSSARY.md is cheap to load (just keyword mappings), and the full docs only get loaded when relevant.

## Auto-Updates

Memex automatically checks for updates when a Claude Code session starts. If updates are available, they're pulled and installed automatically.

### How It Works

1. On install, memex stores its source path in `.claude/.memex-source`
2. On session start, `session-start.sh` checks if the memex repo has new commits
3. If updates exist, memex pulls and re-runs the installer

### Disabling Auto-Updates

Set the environment variable to disable:

```bash
export MEMEX_UPDATES_DISABLED=TRUE
```

Add to your shell profile (`.bashrc`, `.zshrc`) to disable permanently.

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
│       ├── scan-docs.sh          # Auto-glossary generator utility
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

### Utility: scan-docs.sh

The `scan-docs.sh` utility helps generate glossary entries:

```bash
# Scan all docs and suggest keywords
./scan-docs.sh

# Scan a specific file
./scan-docs.sh docs/core/API.md

# Check for unmapped documentation
./scan-docs.sh --check
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
| `MEMEX_UPDATES_DISABLED` | Set to `TRUE` to disable auto-updates |
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
