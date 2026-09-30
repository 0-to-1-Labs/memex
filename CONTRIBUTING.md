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

1. Fork the repository (`https://github.com/0-to-1-Labs/memex`)
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes following the code style guidelines below
4. Test your changes locally (see Testing section)
5. Commit with clear messages: `git commit -m "fix: handle colons in file names"`
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

### Bash 3.2 Compatibility

macOS ships with bash 3.2, so all scripts must be compatible, and they must
also run on GNU tools (Linux).

**DO NOT use:**
- Associative arrays (`declare -A`)
- `mapfile` / `readarray`
- `${var,,}` / `${var^^}` (lowercase/uppercase)
- `|&` (pipe stderr)
- `head -n -1`, `grep -P`, `sed -i` without a suffix, `date +%N` unguarded
- awk interval expressions (`{3,}`), `asort`, or NUL record separators
- `grep -Z` (it means "decompress" on BSD grep; use `--null`)

**DO use:**
- Indexed arrays (`declare -a`)
- `tr '[:upper:]' '[:lower:]'` for case conversion
- `case` statements for pattern matching, POSIX classes (`[[:upper:]]`)
- `LC_ALL=C` at the top of every hook (bash 3.2 `[A-Z]` ranges are wrong
  under a UTF-8 locale)
- Standard POSIX-compatible constructs; `[[ ]]`, `=~` with `BASH_REMATCH`,
  and `&>` work on bash 3.2 and are fine

### General Guidelines

- **No blanket `set -e` in hooks.** A hook must always emit what it has and
  exit 0; guard each risky command explicitly. `install.sh` uses `set -e` and
  guards the commands that may fail (`|| true`).
- Quote all variables: `"$var"` not `$var`
- Hooks are read-only over the repo, except the opt-in session-end archive.
  Any file the enricher reads must pass `path_in_project` (no `..`, no
  absolute path, no symlink, physical path inside the project root).
- Keep every stage a single `grep`/`sort`/`awk` pass; never loop in bash over
  search hits (that is what made the 1.x hook take 28 s on 440 files).
- Telemetry sends counts only: never add prompt words, file paths, the
  project name, or the hostname to an attribute.
- Add comments for non-obvious logic; keep functions focused and small

### jq Dependency

The hooks require `jq` for JSON parsing. This is documented in the installation process.

## Testing

### Automated tests

```bash
bash tests/run-tests.sh
```

The runner is dependency-free bash (needs `jq`, `git`, `tar`). It builds
throwaway projects in a temp directory, sets `HOME` and `TMPDIR` to that
directory, unsets every `OTEL_*` variable, and runs each hook with sample JSON
on stdin. Set `MEMEX_TEST_PERF=0` to skip the 3,000-file timing check.

Also run `bash -n` and `shellcheck` on every script, and
`claude plugin validate .` on the plugin.

### Test Individual Hooks

Never point `CLAUDE_PROJECT_DIR` at a real project: `session-end.sh` deletes
`docs/working/` when `MEMEX_ARCHIVE_WORKING=TRUE`.

```bash
export CLAUDE_PROJECT_DIR=/tmp/test-project
export CLAUDE_PLUGIN_ROOT=/path/to/memex

# context-enricher (UserPromptSubmit hook)
echo '{"prompt": "tell me about the database schema", "session_id": "test"}' | bash .claude/hooks/context-enricher.sh

# session-start (SessionStart hook)
echo '{"session_id": "test", "source": "startup"}' | bash .claude/hooks/session-start.sh

# validate-docs (PostToolUse hook)
echo '{"session_id": "test", "tool_name": "Write", "tool_input": {"file_path": "/tmp/test-project/docs/test.md"}}' | bash .claude/hooks/validate-docs.sh

# session-end (SessionEnd hook; archiving is opt-in)
echo '{"session_id": "test", "reason": "other"}' | bash .claude/hooks/session-end.sh
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
| `install.sh` | Installer script (installer mode) |
| `hooks/hooks.json` | Hook registration, matchers, and timeouts (plugin mode) |
| `.claude/hooks/context-enricher.sh` | Lexical retrieval and doc injection |
| `.claude/hooks/session-start.sh` | Short session status, cache housekeeping |
| `.claude/hooks/session-end.sh` | Archives working documents (opt-in) |
| `.claude/hooks/validate-docs.sh` | Size limit warnings (JSON `additionalContext`) |
| `.claude/hooks/telemetry.sh` | OpenTelemetry helper (counts only) |
| `templates/*.template` | Templates for new installations |
| `tests/run-tests.sh` | Hook tests |

## Development Commands

See the [CLAUDE.md](CLAUDE.md) file for detailed development commands and architecture information.

## Questions?

Open an issue for any questions about contributing.
