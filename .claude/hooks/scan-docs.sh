#!/bin/bash
# =============================================================================
# Documentation Scanner - Auto-Glossary Generator
# =============================================================================
# Scans documentation files and suggests keyword mappings for GLOSSARY.md.
#
# Usage:
#   ./scan-docs.sh                    # Scan all docs
#   ./scan-docs.sh docs/core/API.md   # Scan specific file
#   ./scan-docs.sh --check            # Check for unmapped keywords
#
# Output:
#   - Extracts headers and suggests keywords
#   - Identifies potential glossary entries
#   - Reports unmapped headers not in GLOSSARY.md
# =============================================================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
DOCS_DIR="$PROJECT_ROOT/docs"
GLOSSARY_PATH="$DOCS_DIR/GLOSSARY.md"

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# =============================================================================
# Functions
# =============================================================================

# Slugify a header into an anchor
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-'
}

# Extract keywords from a header
extract_keywords() {
    local header="$1"
    # Remove common words, split on spaces, lowercase
    echo "$header" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 -' | tr ' ' '\n' | \
        grep -v -E '^(the|a|an|and|or|for|to|in|on|of|with|is|are|be|this|that|how|what|when|where|why)$' | \
        grep -E '.{3,}' | sort -u
}

# Check if a keyword exists in GLOSSARY.md
keyword_in_glossary() {
    local keyword="$1"
    grep -qi "^\- \*\*$keyword\*\*" "$GLOSSARY_PATH" 2>/dev/null
}

# Scan a single file
scan_file() {
    local file="$1"
    local rel_path="${file#$PROJECT_ROOT/}"
    local doc_path="${file#$DOCS_DIR/}"

    echo -e "${BLUE}Scanning:${NC} $rel_path"
    echo "----------------------------------------"

    local section_count=0
    local suggested_keywords=""

    while IFS= read -r line; do
        # Match ## and ### headers (not # which is title)
        if [[ "$line" =~ ^(##[#]?)[[:space:]]+(.*) ]]; then
            local level="${BASH_REMATCH[1]}"
            local header="${BASH_REMATCH[2]}"
            local anchor=$(slugify "$header")

            section_count=$((section_count + 1))

            # Generate suggested glossary entry
            local entry_path="$doc_path#$anchor"
            echo -e "  ${GREEN}$level${NC} $header"
            echo -e "      -> ${YELLOW}$entry_path${NC}"

            # Extract and suggest keywords
            local keywords=$(extract_keywords "$header")
            for kw in $keywords; do
                if ! keyword_in_glossary "$kw"; then
                    suggested_keywords="$suggested_keywords\n- **$kw** -> \`$entry_path\` - $header"
                fi
            done
        fi
    done < "$file"

    echo ""
    echo "Sections found: $section_count"

    if [ -n "$suggested_keywords" ]; then
        echo ""
        echo -e "${YELLOW}Suggested glossary entries (not currently in GLOSSARY.md):${NC}"
        echo -e "$suggested_keywords"
    fi

    echo ""
}

# Scan all docs
scan_all() {
    echo "=============================================="
    echo "  DOCUMENTATION SCANNER"
    echo "=============================================="
    echo ""
    echo "Scanning: $DOCS_DIR"
    echo ""

    local total_files=0
    local total_sections=0

    # Find all markdown files except GLOSSARY.md
    for file in $(find "$DOCS_DIR" -name "*.md" -type f | grep -v "GLOSSARY.md" | sort); do
        scan_file "$file"
        total_files=$((total_files + 1))
        echo "=============================================="
        echo ""
    done

    echo ""
    echo "Total files scanned: $total_files"
}

# Check for unmapped sections
check_unmapped() {
    echo "=============================================="
    echo "  CHECKING FOR UNMAPPED DOCUMENTATION"
    echo "=============================================="
    echo ""

    local unmapped=""

    for file in $(find "$DOCS_DIR" -name "*.md" -type f | grep -v "GLOSSARY.md" | sort); do
        local doc_path="${file#$DOCS_DIR/}"

        while IFS= read -r line; do
            if [[ "$line" =~ ^(##)[[:space:]]+(.*) ]]; then
                local header="${BASH_REMATCH[2]}"
                local anchor=$(slugify "$header")
                local full_ref="$doc_path#$anchor"

                # Check if this section is referenced in GLOSSARY.md
                if ! grep -q "$doc_path" "$GLOSSARY_PATH" 2>/dev/null; then
                    unmapped="$unmapped\n  - $full_ref ($header)"
                fi
            fi
        done < "$file"
    done

    if [ -n "$unmapped" ]; then
        echo -e "${YELLOW}Files/sections not referenced in GLOSSARY.md:${NC}"
        echo -e "$unmapped"
        echo ""
        echo "Consider adding these to improve keyword discoverability."
    else
        echo -e "${GREEN}All documentation files are referenced in GLOSSARY.md${NC}"
    fi

    echo ""
}

# =============================================================================
# Main
# =============================================================================

case "$1" in
    --check|-c)
        check_unmapped
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS] [FILE]"
        echo ""
        echo "Options:"
        echo "  --check, -c    Check for unmapped documentation"
        echo "  --help, -h     Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0                           # Scan all docs"
        echo "  $0 docs/core/API.md          # Scan specific file"
        echo "  $0 --check                   # Check for unmapped sections"
        ;;
    "")
        scan_all
        ;;
    *)
        if [ -f "$1" ]; then
            scan_file "$1"
        elif [ -f "$DOCS_DIR/$1" ]; then
            scan_file "$DOCS_DIR/$1"
        else
            echo "File not found: $1"
            exit 1
        fi
        ;;
esac
