# Contributing to Memex

Thank you for your interest in contributing to Memex! This guide will help you get started.

## Reporting Issues

When reporting an issue, please include:

1. **Your environment**: macOS/Linux version, bash version (`bash --version`)
2. **Steps to reproduce**: Minimal steps to trigger the issue
3. **Expected behavior**: What you expected to happen
4. **Actual behavior**: What actually happened
5. **Relevant logs**: Any error messages or hook output

## Submitting Pull Requests

### Before You Start

1. Check existing issues/PRs to avoid duplicate work
2. For major changes, open an issue first to discuss the approach

### PR Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes following the code style guidelines below
4. Test your changes locally (see Testing section)
5. Commit with clear messages: `git commit -m "feat: add new keyword mapping"`
6. Push and open a PR against `main`

### Commit Message Format

Use conventional commit prefixes:

- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `refactor:` - Code restructuring
- `test:` - Test additions/changes
- `chore:` - Maintenance tasks

## Code Style

### Bash 3.x Compatibility

macOS ships with bash 3.x, so all scripts must be compatible:

**DO NOT use:**
- Associative arrays (`declare -A`)
- `mapfile` / `readarray`
- `${var,,}` / `${var^^}` (lowercase/uppercase)
- `[[ $var =~ regex ]]` with capture groups
- `|&` (pipe stderr)
- `&>` for redirection (use `>file 2>&1` instead)

**DO use:**
- Indexed arrays (`declare -a`)
- `tr '[:upper:]' '[:lower:]'` for case conversion
- `case` statements for pattern matching
- Standard POSIX-compatible constructs

### General Guidelines

- Use `set -e` at the top of scripts
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals (supported in bash 3.x)
- Add comments for non-obvious logic
- Keep functions focused and small

### jq Dependency

The hooks require `jq` for JSON parsing. This is documented in the installation process.

## Testing Hooks Locally

After making changes, test the hooks in a target project.

### Install to a Test Project

```bash
# Create a test directory
mkdir -p /tmp/test-project
cd /tmp/test-project
git init

# Install memex (from your fork/branch)
/path/to/your/memex/install.sh /tmp/test-project
```

### Test Individual Hooks

```bash
# Test context-enricher (UserPromptSubmit hook)
echo '{"prompt": "tell me about the database schema", "session_id": "test"}' | .claude/hooks/context-enricher.sh

# Test session-start (SessionStart hook)
.claude/hooks/session-start.sh

# Test validate-docs (PostToolUse hook)
echo '{"tool_name": "Write", "tool_input": {"file_path": "docs/test.md"}}' | .claude/hooks/validate-docs.sh
```

### Test Installation Scenarios

```bash
# Fresh install
./install.sh /tmp/fresh-project

# Reinstall (update existing)
./install.sh /tmp/fresh-project

# Force mode (no prompts)
./install.sh -f /tmp/fresh-project

# Separate worktree
./install.sh /config/path -w /worktree/path

# Skip migration
./install.sh --no-migration /tmp/fresh-project
```

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Main installer script |
| `.claude/hooks/context-enricher.sh` | Keyword matching and doc injection |
| `.claude/hooks/session-start.sh` | Git status, update checks |
| `.claude/hooks/session-end.sh` | Archives working documents |
| `.claude/hooks/validate-docs.sh` | Size limit warnings |
| `templates/*.template` | Templates for new installations |

## Development Commands

See the [CLAUDE.md](CLAUDE.md) file for detailed development commands and architecture information.

## Questions?

Open an issue for any questions about contributing.
