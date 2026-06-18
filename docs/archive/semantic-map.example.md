# Semantic Map Example

This is an example of a comprehensive keyword-to-documentation mapping.
You can create a similar file for your project to enable the docs-loader skill.

---

## Keyword Index

### A

| Keyword | Primary Doc | Section | Secondary |
|---------|------------|---------|-----------|
| api | API.md | - | CLAUDE.md |
| authentication | API.md | #authentication | - |
| architecture | ARCHITECTURE.md | #overview | - |

### B

| Keyword | Primary Doc | Section | Secondary |
|---------|------------|---------|-----------|
| build | DEPLOYMENT.md | #build | - |
| backend | ARCHITECTURE.md | #backend | - |

### C

| Keyword | Primary Doc | Section | Secondary |
|---------|------------|---------|-----------|
| config | ARCHITECTURE.md | #configuration | - |
| container | ARCHITECTURE.md | #docker | DEPLOYMENT.md |

### D

| Keyword | Primary Doc | Section | Secondary |
|---------|------------|---------|-----------|
| database | DATABASE.md | - | - |
| deploy | DEPLOYMENT.md | - | - |
| docker | ARCHITECTURE.md | #docker | DEPLOYMENT.md |

### E

| Keyword | Primary Doc | Section | Secondary |
|---------|------------|---------|-----------|
| endpoint | API.md | #endpoints | - |
| environment | ARCHITECTURE.md | #environment | DEPLOYMENT.md |
| error | TROUBLESHOOTING.md | - | API.md#errors |

---

## Semantic Clusters

Related concepts that often need to be loaded together.

### Infrastructure
```
ARCHITECTURE.md     - System design
DEPLOYMENT.md       - Deployment process
TROUBLESHOOTING.md  - Common issues
```

### Data Layer
```
DATABASE.md         - Schema, tables, queries
API.md              - Database access patterns
```

### API Development
```
API.md              - Route patterns, auth
DATABASE.md         - Query patterns
CLAUDE.md           - Key files, constraints
```

---

## Common Question Patterns

### "How do I..."

| Question Pattern | Start With | Load Next |
|-----------------|-----------|-----------|
| ...add an API endpoint? | API.md | DATABASE.md if DB involved |
| ...deploy changes? | DEPLOYMENT.md | - |
| ...add a database table? | DATABASE.md#schema | API.md |

### "What is..."

| Question Pattern | Load Doc | Section |
|-----------------|---------|---------|
| ...the database schema? | DATABASE.md | #schema |
| ...the deployment process? | DEPLOYMENT.md | #pipeline |

### "Why does..."

| Question Pattern | Start With | Context From |
|-----------------|-----------|--------------|
| ...API return 401? | API.md#authentication | - |
| ...database query fail? | DATABASE.md | TROUBLESHOOTING.md |

---

## Loading Priority

When multiple docs are relevant, load in this order:

### For Implementation Tasks
1. GLOSSARY.md (keyword lookup)
2. Specific doc section (targeted info)
3. Related doc sections (context)
4. Full docs if needed

### For Debugging Tasks
1. TROUBLESHOOTING.md (error patterns)
2. Specific component doc
3. ARCHITECTURE.md (system context)

---

This semantic map enables intelligent, token-efficient documentation loading.
