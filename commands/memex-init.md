---
name: memex-init
description: Scaffold the Memex documentation structure (docs/ tree, GLOSSARY.md, CONTRIBUTING.md) and add the Memex section to CLAUDE.md. Run once per project after installing the Memex plugin.
allowed-tools: Bash(mkdir:*), Bash(cp:*), Bash(test:*), Bash(cat:*), Bash(sed:*), Bash(grep:*), Bash(basename:*), Bash(date:*), Read, Write, Edit
---

# Initialize Memex in this project

The Memex hooks (context-enricher, validate-docs, session-start/end) are already
active via the plugin. This command creates the project-local files those hooks
read from: the `docs/` tree, a starter `GLOSSARY.md`, `CONTRIBUTING.md`, and the
Memex section in `CLAUDE.md`.

It is **idempotent** — existing files are preserved, never overwritten.

Run the following scaffold. Templates ship with the plugin under
`${CLAUDE_PLUGIN_ROOT}/templates/`.

```bash
set -e
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TPL="${CLAUDE_PLUGIN_ROOT}/templates"
PROJECT_NAME="$(basename "$ROOT")"
TODAY="$(date +%Y-%m-%d)"

# 1. Documentation tree
mkdir -p "$ROOT/docs/core" "$ROOT/docs/features" "$ROOT/docs/working" "$ROOT/docs/archive"

# 2. working/ is for throwaway notes - keep the dir, ignore its contents
if [ ! -f "$ROOT/docs/working/.gitignore" ]; then
  printf '*\n!.gitignore\n' > "$ROOT/docs/working/.gitignore"
fi

# 3. GLOSSARY.md - the keyword -> doc map the context-enricher reads at runtime
if [ ! -f "$ROOT/docs/GLOSSARY.md" ]; then
  sed -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" -e "s/{{DATE}}/$TODAY/g" \
    "$TPL/GLOSSARY.md.template" > "$ROOT/docs/GLOSSARY.md"
  echo "+ docs/GLOSSARY.md"
else
  echo "~ docs/GLOSSARY.md (exists, preserved)"
fi

# 4. CONTRIBUTING.md - documentation size/style guidelines
if [ ! -f "$ROOT/docs/CONTRIBUTING.md" ]; then
  sed -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" -e "s/{{DATE}}/$TODAY/g" \
    "$TPL/CONTRIBUTING.md.template" > "$ROOT/docs/CONTRIBUTING.md"
  echo "+ docs/CONTRIBUTING.md"
else
  echo "~ docs/CONTRIBUTING.md (exists, preserved)"
fi

# 5. CLAUDE.md - append the Memex section if not already present
MARKER="<!-- MEMEX:AUTO-GENERATED -->"
if [ -f "$ROOT/CLAUDE.md" ] && grep -q "$MARKER" "$ROOT/CLAUDE.md" 2>/dev/null; then
  echo "~ CLAUDE.md (memex section exists)"
else
  {
    echo ""
    echo "$MARKER"
    echo "# Memex Documentation System"
    echo ""
    tail -n +2 "$TPL/CLAUDE.md.template" | sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g"
  } >> "$ROOT/CLAUDE.md"
  echo "+ CLAUDE.md (memex section appended)"
fi

echo ""
echo "Memex initialized. Edit docs/GLOSSARY.md to map keywords to your docs."
```

After running, briefly tell the user:
1. Memex is initialized and the docs structure is ready.
2. They should populate `docs/GLOSSARY.md` with `- **keyword** -> \`docs/path/FILE.md#section\`` entries — that map drives keyword-based auto-loading.
3. The `memex-docs` skill provides the writing guidelines and will activate when they edit docs.
