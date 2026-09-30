#!/bin/bash
# =============================================================================
# Memex Installer
# =============================================================================
# Sets up the context-aware documentation system for Claude Code.
#
# Usage:
#   ./install.sh [options] [project_path]
#
# Options:
#   -f, --force         Skip confirmation prompts
#   -w, --worktree      Specify git worktree path (for docs/)
#   --no-migration      Skip automatic documentation migration
#
# Installation targets:
#   - Claude Code config (hooks, settings, skills) -> PROJECT_ROOT/.claude/
#   - CLAUDE.md -> PROJECT_ROOT/CLAUDE.md
#   - Documentation templates -> WORKTREE/docs/ (git worktree)
#
# Behavior for existing files:
#   - CLAUDE.md: Append memex section (idempotent - won't duplicate)
#   - GLOSSARY.md: Backup to .old, install latest
#   - CONTRIBUTING.md: Backup to .old, install latest
#   - Hooks: Always overwrite with latest
#   - settings.json: Merge hooks (preserve other settings)
#   - Skills: Add new skills, preserve existing customizations
#
# Documentation Migration (default: enabled):
#   - Discovers .md files outside docs/
#   - Deduplicates by content hash (MD5)
#   - Archives originals to docs/archive/
#   - Migrates to docs/core/ or docs/features/ based on filename
#   - docs/archive/ is excluded from context loading
#
# Updates:
#   - Plugin mode: run `/plugin update` to pull the latest Memex.
#   - Installer mode: re-run this script (./install.sh -f <project>) to update.
#   - No automatic git fetch/pull or remote code execution happens on session
#     start; updates are always an explicit, user-initiated action.
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Show usage if no arguments provided
# -----------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    echo "Usage: ./install.sh [options] <project_path>"
    echo ""
    echo "Options:"
    echo "  -f, --force         Skip confirmation prompts"
    echo "  -w, --worktree      Specify git worktree path (for docs/)"
    echo "  --no-migration      Skip automatic documentation migration"
    echo ""
    echo "Examples:"
    echo "  ./install.sh /path/to/project"
    echo "  ./install.sh -f /path/to/project"
    echo "  ./install.sh /config/path -w /worktree/path"
    echo ""
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Memex marker for idempotent CLAUDE.md append
MEMEX_MARKER="<!-- MEMEX:AUTO-GENERATED -->"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Memex - Documentation Memory System${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
PROJECT_ROOT=""
WORKTREE=""
FORCE_MODE=0
NO_MIGRATION=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE_MODE=1
            shift
            ;;
        -w|--worktree)
            WORKTREE="$2"
            shift 2
            ;;
        --no-migration)
            NO_MIGRATION=1
            shift
            ;;
        *)
            if [ -z "$PROJECT_ROOT" ]; then
                PROJECT_ROOT="$1"
            fi
            shift
            ;;
    esac
done

# Default PROJECT_ROOT to current directory
if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(pwd)"
fi

# Expand to absolute path
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# -----------------------------------------------------------------------------
# Detect worktree (git repository root)
# -----------------------------------------------------------------------------
if [ -z "$WORKTREE" ]; then
    # Try to find git worktree
    if [ -d "$PROJECT_ROOT/.git" ] || [ -f "$PROJECT_ROOT/.git" ]; then
        WORKTREE="$PROJECT_ROOT"
    elif command -v git &> /dev/null; then
        WORKTREE=$(cd "$PROJECT_ROOT" && git rev-parse --show-toplevel 2>/dev/null) || WORKTREE="$PROJECT_ROOT"
    else
        WORKTREE="$PROJECT_ROOT"
    fi
fi

# Expand worktree to absolute path
WORKTREE="$(cd "$WORKTREE" 2>/dev/null && pwd)" || WORKTREE="$PROJECT_ROOT"

echo -e "Claude config:  ${GREEN}$PROJECT_ROOT${NC}"
echo -e "Git worktree:   ${GREEN}$WORKTREE${NC}"
echo ""

# -----------------------------------------------------------------------------
# Check for existing .claude directory (interactive mode only)
# -----------------------------------------------------------------------------
if [ -d "$PROJECT_ROOT/.claude" ] && [ "$FORCE_MODE" -eq 0 ] && [ -t 0 ]; then
    echo -e "${YELLOW}Note: .claude directory already exists. Hooks will be updated.${NC}"
    read -p "Continue? (Y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
fi

# -----------------------------------------------------------------------------
# Get script directory (where memex files are)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Create directory structure
# -----------------------------------------------------------------------------
echo "Creating directories..."
mkdir -p "$PROJECT_ROOT/.claude/hooks"
mkdir -p "$PROJECT_ROOT/.claude/skills"
mkdir -p "$WORKTREE/docs/core"
mkdir -p "$WORKTREE/docs/features"
mkdir -p "$WORKTREE/docs/archive"
mkdir -p "$WORKTREE/docs/working"

# Add .gitkeep to working directory
touch "$WORKTREE/docs/working/.gitkeep"

# Add .gitignore for working directory (don't commit temp files)
if [ ! -f "$WORKTREE/docs/working/.gitignore" ]; then
    cat > "$WORKTREE/docs/working/.gitignore" << 'EOF'
*
!.gitkeep
!.gitignore
EOF
fi

# -----------------------------------------------------------------------------
# Documentation Migration (unless --no-migration)
# -----------------------------------------------------------------------------
if [ "$NO_MIGRATION" -eq 0 ]; then
    echo "Discovering existing documentation..."

    MIGRATION_COUNT=0
    DUPLICATE_COUNT=0

    # Create hash tracking file
    HASH_FILE="$WORKTREE/docs/archive/.content-hashes"
    touch "$HASH_FILE"

    # Find all .md files outside docs/ directory
    while IFS= read -r -d '' md_file; do
        # Skip files already in docs/
        case "$md_file" in
            "$WORKTREE/docs/"*) continue ;;
        esac

        # Skip CLAUDE.md (handled separately)
        if [[ "$(basename "$md_file")" == "CLAUDE.md" ]]; then
            continue
        fi

        # Skip hidden directories (.git, .claude, .github, .venv, ...) and
        # dependency/build output. Without this, a second run would ingest the
        # skills this installer copied into .claude/ and GitHub templates.
        case "${md_file#"$WORKTREE"/}" in
            .*|*/.*) continue ;;
            node_modules/*|*/node_modules/*|vendor/*|*/vendor/*) continue ;;
            venv/*|*/venv/*|build/*|*/build/*|dist/*|*/dist/*|target/*|*/target/*) continue ;;
        esac

        # Calculate content hash (MD5)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            CONTENT_HASH=$(md5 -q "$md_file" 2>/dev/null)
        else
            CONTENT_HASH=$(md5sum "$md_file" 2>/dev/null | cut -d' ' -f1)
        fi

        # Check for duplicate content
        if grep -q "^$CONTENT_HASH " "$HASH_FILE" 2>/dev/null; then
            DUPLICATE_COUNT=$((DUPLICATE_COUNT + 1))
            echo -e "  ${YELLOW}~${NC} $(basename "$md_file") (duplicate, skipped)"
            continue
        fi

        # Determine target location based on filename/content
        FILENAME=$(basename "$md_file")
        FILENAME_UPPER=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]')

        # Categorize: core docs vs feature docs
        case "$FILENAME_UPPER" in
            *ARCHITECTURE*|*DATABASE*|*API*|*SCHEMA*|*CONFIG*)
                TARGET_DIR="$WORKTREE/docs/core"
                ;;
            *README*|*CHANGELOG*|*LICENSE*|*CONTRIBUTING*|*CODE_OF_CONDUCT*)
                # Keep these in archive only (they're project meta-docs)
                TARGET_DIR=""
                ;;
            *)
                TARGET_DIR="$WORKTREE/docs/features"
                ;;
        esac

        # Archive the original
        ARCHIVE_PATH="$WORKTREE/docs/archive/$FILENAME"
        if [ -f "$ARCHIVE_PATH" ]; then
            # Add timestamp to avoid overwriting
            ARCHIVE_PATH="$WORKTREE/docs/archive/${FILENAME%.md}_$(date +%Y%m%d%H%M%S).md"
        fi
        cp "$md_file" "$ARCHIVE_PATH"

        # Record hash
        echo "$CONTENT_HASH $ARCHIVE_PATH" >> "$HASH_FILE"

        # Copy to target location (if not just archiving)
        if [ -n "$TARGET_DIR" ]; then
            TARGET_PATH="$TARGET_DIR/$FILENAME"
            if [ ! -f "$TARGET_PATH" ]; then
                cp "$md_file" "$TARGET_PATH"
                echo -e "  ${GREEN}+${NC} $FILENAME -> $(basename "$TARGET_DIR")/"
            else
                echo -e "  ${YELLOW}~${NC} $FILENAME (target exists, archived only)"
            fi
        else
            echo -e "  ${BLUE}→${NC} $FILENAME -> archive/"
        fi

        MIGRATION_COUNT=$((MIGRATION_COUNT + 1))

    done < <(find "$WORKTREE" -name "*.md" -type f -print0 2>/dev/null)

    if [ "$MIGRATION_COUNT" -gt 0 ]; then
        echo -e "  Migrated: ${GREEN}$MIGRATION_COUNT${NC} files"
        [ "$DUPLICATE_COUNT" -gt 0 ] && echo -e "  Duplicates skipped: ${YELLOW}$DUPLICATE_COUNT${NC}"
    else
        echo -e "  ${BLUE}(no documentation found to migrate)${NC}"
    fi
    echo ""
else
    echo -e "${YELLOW}Skipping documentation migration (--no-migration)${NC}"
    echo ""
fi

# -----------------------------------------------------------------------------
# Copy and configure hooks (always overwrite)
# -----------------------------------------------------------------------------
echo "Installing hooks..."

# Hooks resolve the project root at runtime via $CLAUDE_PROJECT_DIR (set by
# Claude Code), so no path substitution is needed - the same scripts work
# whether copied by this installer or loaded as a plugin.
for hook in session-start.sh session-end.sh context-enricher.sh validate-docs.sh; do
    if [ -f "$SCRIPT_DIR/.claude/hooks/$hook" ]; then
        cp "$SCRIPT_DIR/.claude/hooks/$hook" "$PROJECT_ROOT/.claude/hooks/$hook"
        chmod +x "$PROJECT_ROOT/.claude/hooks/$hook"
        echo -e "  ${GREEN}+${NC} $hook"
    fi
done

# Copy telemetry helper (sourced by other hooks, no PROJECT_ROOT needed)
if [ -f "$SCRIPT_DIR/.claude/hooks/telemetry.sh" ]; then
    cp "$SCRIPT_DIR/.claude/hooks/telemetry.sh" "$PROJECT_ROOT/.claude/hooks/telemetry.sh"
    chmod +x "$PROJECT_ROOT/.claude/hooks/telemetry.sh"
    echo -e "  ${GREEN}+${NC} telemetry.sh"
fi

# -----------------------------------------------------------------------------
# Install skills (append - don't overwrite existing)
# -----------------------------------------------------------------------------
echo "Installing skills..."

SKILLS_INSTALLED=0

# Install from skills/ (canonical source directory for all bundled skills)
if [ -d "$SCRIPT_DIR/skills" ]; then
    for skill_dir in "$SCRIPT_DIR/skills"/*/; do
        if [ -d "$skill_dir" ]; then
            skill_name=$(basename "$skill_dir")
            if [ -d "$PROJECT_ROOT/.claude/skills/$skill_name" ]; then
                echo -e "  ${YELLOW}~${NC} $skill_name (exists, preserved)"
            else
                mkdir -p "$PROJECT_ROOT/.claude/skills/$skill_name"
                cp -r "$skill_dir"* "$PROJECT_ROOT/.claude/skills/$skill_name/" 2>/dev/null || true
                echo -e "  ${GREEN}+${NC} $skill_name"
                SKILLS_INSTALLED=$((SKILLS_INSTALLED + 1))
            fi
        fi
    done
fi

if [ "$SKILLS_INSTALLED" -eq 0 ]; then
    echo -e "  ${BLUE}(all skills already installed)${NC}"
fi

# -----------------------------------------------------------------------------
# Merge settings.json (preserve existing settings, add/update hooks)
# -----------------------------------------------------------------------------
echo "Configuring settings.json..."

MEMEX_HOOKS=$(cat << EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$PROJECT_ROOT/.claude/hooks/session-start.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$PROJECT_ROOT/.claude/hooks/session-end.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$PROJECT_ROOT/.claude/hooks/context-enricher.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "^(Write|Edit)$",
        "hooks": [
          {
            "type": "command",
            "command": "$PROJECT_ROOT/.claude/hooks/validate-docs.sh"
          }
        ]
      }
    ]
  }
}
EOF
)

SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"
SETTINGS_SKIPPED=0

if [ -f "$SETTINGS_FILE" ] && ! command -v jq &> /dev/null; then
    # Never overwrite an existing settings file without being able to merge it.
    echo -e "  ${YELLOW}!${NC} settings.json exists and jq is not installed: not modified."
    echo "    Install jq and re-run, or add the memex hooks by hand."
    SETTINGS_SKIPPED=1
elif [ -f "$SETTINGS_FILE" ]; then
    # Merge with existing settings (deep merge hooks). Back up first.
    SETTINGS_BACKUP="$SETTINGS_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS_FILE" "$SETTINGS_BACKUP"
    EXISTING=$(cat "$SETTINGS_FILE")

    # Merge memex hooks into existing settings WITHOUT clobbering other hooks.
    #
    # `. * $memex` deep-merges but *replaces* same-event hook arrays, wiping out
    # any pre-existing hooks the user has under SessionStart/PostToolUse/etc.
    # Instead, for each event in $memex.hooks we APPEND memex's hook groups to
    # the user's existing array for that event, then de-duplicate by the set of
    # command strings each group contains so re-running install is idempotent
    # (memex's own entries are not duplicated). All non-hook settings, and hooks
    # for events memex does not touch, are left exactly as-is.
    # `|| true` keeps `set -e` from aborting the install when the file is not
    # strict JSON (for example, it contains comments): we report and move on.
    MERGED=$(echo "$EXISTING" | jq --argjson memex "$MEMEX_HOOKS" '
        # commands(group): sorted list of command strings within a hook group,
        # used as the de-dup identity for that group.
        def commands(group): [group.hooks[]? | .command] | sort;

        . as $base
        | reduce ($memex.hooks | to_entries[]) as $evt (
            $base;
            .hooks[$evt.key] = (
                ((.hooks // {})[$evt.key] // []) as $existing
                | reduce $evt.value[] as $grp (
                    $existing;
                    if any(.[]?; commands(.) == commands($grp))
                    then .
                    else . + [$grp]
                    end
                )
            )
        )
    ' 2>/dev/null) || true

    if [ -n "$MERGED" ] && [ "$MERGED" != "null" ] && printf '%s' "$MERGED" | jq -e '.hooks' >/dev/null 2>&1; then
        echo "$MERGED" > "$SETTINGS_FILE"
        echo -e "  ${GREEN}*${NC} settings.json (merged; backup: $(basename "$SETTINGS_BACKUP"))"
    else
        # Never replace the user's settings with only the memex hooks.
        rm -f "$SETTINGS_BACKUP"
        echo -e "  ${YELLOW}!${NC} settings.json is not valid JSON: not modified."
        echo "    Fix the file (or remove comments) and re-run, or add the memex hooks by hand."
        SETTINGS_SKIPPED=1
    fi
else
    # No existing file - create new
    echo "$MEMEX_HOOKS" > "$SETTINGS_FILE"
    echo -e "  ${GREEN}+${NC} settings.json"
fi

# -----------------------------------------------------------------------------
# CLAUDE.md - Append memex section if not present
# -----------------------------------------------------------------------------
echo "Configuring CLAUDE.md..."

CLAUDE_FILE="$PROJECT_ROOT/CLAUDE.md"
PROJECT_NAME=$(basename "$WORKTREE")

if [ -f "$CLAUDE_FILE" ]; then
    # Check if memex section already exists
    if grep -q "$MEMEX_MARKER" "$CLAUDE_FILE" 2>/dev/null; then
        echo -e "  ${YELLOW}~${NC} CLAUDE.md (memex section exists)"
    else
        # Append memex section
        if [ -f "$SCRIPT_DIR/templates/CLAUDE.md.template" ]; then
            echo "" >> "$CLAUDE_FILE"
            echo "$MEMEX_MARKER" >> "$CLAUDE_FILE"
            echo "# Memex Documentation System" >> "$CLAUDE_FILE"
            echo "" >> "$CLAUDE_FILE"
            # Append template content (skip the header line)
            tail -n +2 "$SCRIPT_DIR/templates/CLAUDE.md.template" | sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" >> "$CLAUDE_FILE"
            echo -e "  ${GREEN}*${NC} CLAUDE.md (appended memex section)"
        fi
    fi
else
    # Create new CLAUDE.md
    if [ -f "$SCRIPT_DIR/templates/CLAUDE.md.template" ]; then
        echo "$MEMEX_MARKER" > "$CLAUDE_FILE"
        sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" "$SCRIPT_DIR/templates/CLAUDE.md.template" >> "$CLAUDE_FILE"
        echo -e "  ${GREEN}+${NC} CLAUDE.md"
    fi
fi

# -----------------------------------------------------------------------------
# GLOSSARY.md - Backup existing, install latest (in worktree)
# -----------------------------------------------------------------------------
echo "Installing documentation templates..."

GLOSSARY_FILE="$WORKTREE/docs/GLOSSARY.md"
TODAY=$(date +%Y-%m-%d)

if [ -f "$SCRIPT_DIR/templates/GLOSSARY.md.template" ]; then
    if [ -f "$GLOSSARY_FILE" ]; then
        # Backup existing
        mv "$GLOSSARY_FILE" "$GLOSSARY_FILE.old"
        echo -e "  ${YELLOW}~${NC} docs/GLOSSARY.md.old (backed up)"
    fi
    # Install new
    sed -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" -e "s/{{DATE}}/$TODAY/g" \
        "$SCRIPT_DIR/templates/GLOSSARY.md.template" > "$GLOSSARY_FILE"
    echo -e "  ${GREEN}+${NC} docs/GLOSSARY.md"
fi

# -----------------------------------------------------------------------------
# CONTRIBUTING.md - Backup existing, install latest (in worktree)
# -----------------------------------------------------------------------------
CONTRIBUTING_FILE="$WORKTREE/docs/CONTRIBUTING.md"

if [ -f "$SCRIPT_DIR/templates/CONTRIBUTING.md.template" ]; then
    if [ -f "$CONTRIBUTING_FILE" ]; then
        # Backup existing
        mv "$CONTRIBUTING_FILE" "$CONTRIBUTING_FILE.old"
        echo -e "  ${YELLOW}~${NC} docs/CONTRIBUTING.md.old (backed up)"
    fi
    # Install new
    sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" \
        "$SCRIPT_DIR/templates/CONTRIBUTING.md.template" > "$CONTRIBUTING_FILE"
    echo -e "  ${GREEN}+${NC} docs/CONTRIBUTING.md"
fi

# -----------------------------------------------------------------------------
# Check for jq dependency
# -----------------------------------------------------------------------------
echo ""
echo "Checking dependencies..."
if command -v jq &> /dev/null; then
    echo -e "  ${GREEN}+${NC} jq found"
else
    echo -e "  ${YELLOW}!${NC} jq not found - settings.json merge requires jq"
    echo "    macOS: brew install jq"
    echo "    Ubuntu/Debian: apt-get install jq"
    echo "    Alpine: apk add jq"
fi

# -----------------------------------------------------------------------------
# Success message
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Installed components:"
echo "  Claude config:  $PROJECT_ROOT/.claude/"
echo "  Documentation:  $WORKTREE/docs/"
echo ""
if [ "$SETTINGS_SKIPPED" -eq 1 ]; then
    echo -e "${YELLOW}Skipped:${NC}"
    echo "  .claude/settings.json was NOT modified (see above). The hooks are"
    echo "  installed under .claude/hooks/ but are not registered until you add them."
    echo ""
fi
echo "Next steps:"
echo "  1. Add documentation to docs/core/ and docs/features/"
echo "  2. (Optional) Add pin/boost hints to docs/GLOSSARY.md"
echo "  3. Review docs/GLOSSARY.md.old if it was backed up"
echo ""
echo -e "Docs: ${BLUE}https://github.com/0-to-1-Labs/memex${NC}"
echo ""
