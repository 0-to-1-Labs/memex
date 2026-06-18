---
name: memex-docs
description: Use this skill when writing, editing, or creating documentation files (*.md) in the docs/ directory. Provides guidelines for token-efficient documentation that works with the Memex context-enricher system.
---

# Memex Documentation Guidelines

Follow these rules when writing or editing documentation in this project.

## Core Principles

1. **Update existing content first** - Never add new sections when existing ones cover the same topic
2. **Token efficiency** - Every token costs context budget
3. **Section-level loading** - The context-enricher loads specific sections via anchors
4. **Single source of truth** - Document once, reference everywhere

## Size Limits

| Level | Max Lines | Target |
|-------|-----------|--------|
| File | 800 | 400-600 |
| Section | 150 | 50-100 |
| Glossary/Index | 1000 | 500-800 |

**If a file exceeds 800 lines**, split into sub-documents:
```
DATABASE.md (overview + links)
DATABASE_SCHEMA.md
DATABASE_QUERIES.md
DATABASE_MIGRATIONS.md
```

## Required Updates

When adding or changing features, update in this order:

1. **GLOSSARY.md** - Add keywords for discoverability
2. **Specialized doc** - Add/update detailed content
3. **CLAUDE.md** - Only if it affects key files or constraints

## Writing Style

### Use Tables Over Paragraphs

```markdown
# Instead of:
The pool uses minimum 5 connections, maximum 20, timeout 30 seconds.

# Use:
| Setting | Value |
|---------|-------|
| Min connections | 5 |
| Max connections | 20 |
| Timeout | 30s |
```

### Use Anchor Links

```markdown
# Instead of:
See DATABASE.md for query patterns.

# Use:
See [Query Patterns](DATABASE.md#queries).
```

### Keep Code Examples Minimal

Show only relevant parts. Include just enough context to be useful.

## Section Headers

Headers create anchor links for section-level loading:

```markdown
## Main Section       -> #main-section
### Subsection        -> #subsection
```

Use descriptive headers that make good anchor names.

## GLOSSARY.md Format

```markdown
### Category Name

- **keyword** -> `path/to/FILE.md#section` - Brief description
- **another-keyword** -> `path/to/FILE.md` - Brief description
```

## Update vs Add Decision

| Scenario | Action |
|----------|--------|
| Feature enhancement | Update existing section |
| Bug fix with behavior change | Update existing documentation |
| API parameter added | Update existing endpoint docs |
| Net-new feature | Create new section |
| Net-new component | Create new file |

**Signs you should update instead of add:**
- Existing section covers the same component
- Adding would duplicate context
- Old section would become misleading

**When updating, fully replace outdated content.** Don't append "UPDATE:" notes. Documentation should read as current truth.

## Pre-Commit Checklist

- [ ] GLOSSARY.md updated with new keywords
- [ ] No section exceeds 150 lines
- [ ] No file exceeds 800 lines
- [ ] Anchor links used for cross-references
- [ ] Tables used for reference data
