---
name: migrate-docs
description: Migrate existing markdown documentation into the memex docs/ structure. Auto-detects .md files throughout the repo, enables interactive categorization (core/features/working), preserves git history with git mv, and reformats to comply with memex size limits. Use when a user installs memex in a repo with existing documentation.
---

# Migrate Legacy Documentation

This skill guides migration of existing markdown files into the memex documentation structure.

## When to Use

- User installed memex in a repo with existing `.md` files
- User asks to organize/migrate/import legacy docs
- User wants to catalog existing documentation into the glossary

## Migration Workflow

Execute these phases in order, asking user questions at each step.

### Phase 1: Discovery

Scan for markdown files outside the memex structure:

```bash
# Use Glob tool to find all .md files, then filter
find . -name "*.md" -type f
```

**Default exclusions** (skip these automatically):

| Path | Reason |
|------|--------|
| `docs/` | Already in memex structure |
| `.git/` | Git internal |
| `.claude/` | Claude config |
| `node_modules/` | Dependencies |
| `vendor/` | Dependencies |
| `.venv/`, `venv/` | Python virtualenv |
| `dist/`, `build/` | Build output |
| `CHANGELOG.md` | Standard file, not docs |
| `SECURITY.md` | Standard file |
| `CODE_OF_CONDUCT.md` | Standard file |
| `LICENSE.md` | Standard file |
| `.github/*.md` | GitHub templates |

**Present results as table:**

```markdown
Found X markdown files outside docs/:

| # | File | Lines | First Heading |
|---|------|-------|---------------|
| 1 | README.md | 326 | Project Name |
| 2 | api/README.md | 892 | API Documentation |
```

### Phase 2: Interactive Categorization

For each file, show a preview and ask where it should go:

```markdown
--- File 1/5: api/README.md (892 lines) ---

Preview (first 30 lines):
# API Documentation
## Overview
This document describes the REST API...

Where should this file go?
```

Use AskUserQuestion with these options:

| Option | Destination | Use For |
|--------|-------------|---------|
| `core` | `docs/core/` | Architecture, database, API, system-level |
| `features` | `docs/features/` | Feature-specific documentation |
| `working` | `docs/working/` | Temporary notes (gitignored) |
| `skip` | (no action) | Don't migrate this file |

### Phase 3: Pre-Migration Checks

Before moving each file, check:

**1. Size check** - If file exceeds 800 lines:
```markdown
This file has 892 lines (exceeds 800 limit).

Proposed split based on ## headers:

| Output File | Sections | Lines |
|-------------|----------|-------|
| API.md | Overview, Auth | 180 |
| API_ENDPOINTS.md | All endpoints | 450 |
| API_ERRORS.md | Error codes | 262 |

Proceed with split? [yes/no/custom]
```

**2. Conflict check** - If target path exists:
```markdown
Target docs/core/API.md already exists.

Options:
- merge: Append new sections to existing file
- replace: Overwrite existing file
- rename: Use different name (e.g., API_V2.md)
- skip: Don't migrate this file
```

**3. Duplicate filename check** - If same filename in different source dirs:
```markdown
Multiple files named README.md found:
- api/README.md
- scripts/README.md

Suggest unique names based on content/path.
```

### Phase 4: Migration Execution

For each approved file:

**1. Move with git history:**
```bash
git mv source/path/FILE.md docs/{category}/NEWNAME.md
```

**2. For splits**, move original first, then create new files:
```bash
git mv api/README.md docs/core/API.md
# Edit API.md to contain only overview sections
# Write new files for split content
git add docs/core/API_ENDPOINTS.md docs/core/API_ERRORS.md
```

**3. Update internal cross-references** - Find and fix links within migrated files that reference old paths.

### Phase 5: Reformatting

Apply these transformations to migrated content:

**1. Add section anchors** - Ensure headers are anchor-friendly:
```markdown
## Main Section       -> #main-section
### API Endpoints     -> #api-endpoints
```

**2. Convert paragraphs to tables** where data is tabular:
```markdown
# Before:
The timeout is 30 seconds, with max 20 connections and 5 minimum.

# After:
| Setting | Value |
|---------|-------|
| Timeout | 30s |
| Max connections | 20 |
| Min connections | 5 |
```

**3. Truncate oversized sections** - If a section exceeds 150 lines:
- Extract to sub-document
- Leave summary with link: `See [Full Details](FILE_SECTION.md)`

### Phase 6: Glossary Update

After migration, generate GLOSSARY.md entries:

**Extract keywords from headers:**
- Remove stop words (the, a, and, or, for, to, in, on, of, with)
- Use words 3+ characters
- Create anchors from section headers

**Proposed entry format:**
```markdown
### Category Name

- **keyword** -> `docs/core/FILE.md#section` - Brief description
```

**Present to user for confirmation:**
```markdown
Proposed GLOSSARY.md entries:

### API
- **api** -> `docs/core/API.md` - API overview
- **authentication** -> `docs/core/API.md#authentication` - Auth methods
- **endpoints** -> `docs/core/API_ENDPOINTS.md` - Available endpoints

Add these entries? [yes/edit/skip]
```

### Phase 7: Verification

After migration completes, verify and report:

**Run checks:**
- All files under 800 lines
- All sections under 150 lines
- Git history preserved (`git log --follow` works)
- No broken internal links

**Show summary:**
```markdown
Migration Complete!

| Metric | Count |
|--------|-------|
| Files migrated | 4 |
| Files split | 1 (into 3) |
| Files skipped | 2 |
| GLOSSARY entries added | 12 |

Warnings:
- docs/core/API_ENDPOINTS.md section "DELETE" has 142 lines (close to limit)

Next steps:
1. Review migrated files
2. Update context-enricher.sh keywords if needed
3. Commit: git commit -m "Migrate documentation to memex structure"
```

## File Splitting Algorithm

When a file exceeds 800 lines:

1. Parse all `##` headers to find section boundaries
2. Calculate line counts per section
3. Group sections targeting 400-600 lines per output file
4. Minimum 100 lines per split file (avoid tiny fragments)
5. Name splits: `ORIGINAL_SECTION.md`
6. Create overview file with links to splits

**Naming convention:**
```
API.md (892 lines) splits into:
├── API.md (overview, 180 lines)
├── API_ENDPOINTS.md (450 lines)
└── API_ERRORS.md (262 lines)
```

## Edge Cases

| Case | Handling |
|------|----------|
| Empty .md file | Skip with notice |
| Binary file with .md extension | Skip with warning |
| File only has code blocks | Flag for user review |
| Symlinks | Resolve to actual file |
| Files in .gitignore | Skip (not versioned) |
| Non-UTF8 encoding | Warn, attempt conversion |

## Post-Migration

Remind user to:
1. Review migrated files for accuracy
2. Add keywords to `context-enricher.sh` if using keyword-based loading
3. Run `./scan-docs.sh --check` to find any unmapped sections
4. Commit changes with descriptive message
