#!/usr/bin/env bash
# Fail on banned incomplete-work tokens and unambiguous unsafe Swift patterns in
# first-party code (08-validation-commands.md §5, 05-quality-testing-release-gates.md §6).
# Uses `grep -rn` (not `git grep`) so it inspects files regardless of git staging
# state — an untracked file must not produce a false "clean".
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# First-party scan roots (skip ones that do not exist yet).
roots=()
for p in Sources Tests Extensions Scripts .github Makefile project.yml; do
    [ -e "$p" ] && roots+=("$p")
done

# --- Banned incomplete-work tokens ---
# Patterns come from the reviewed policy data file, which is the single excluded
# path so its literals do not self-match.
pattern="$(grep -vE '^\s*#' Scripts/banned-tokens.txt | grep -vE '^\s*$' | paste -sd'|' -)"
if hits="$(grep -rnE "$pattern" "${roots[@]}" \
        --exclude=banned-tokens.txt \
        --exclude-dir=.build --exclude-dir=DerivedData 2>/dev/null)"; then
    echo "ERROR: banned incomplete-work token(s):"
    echo "$hits"
    fail=1
fi

# --- Unambiguous unsafe Swift: try! / as! ---
if hits="$(grep -rnE 'try!|[[:space:]]as!' Sources Tests --include='*.swift' 2>/dev/null)"; then
    echo "ERROR: try!/as! in Swift:"
    echo "$hits"
    fail=1
fi

# --- Empty/silent catch blocks ---
if hits="$(grep -rnE 'catch[[:space:]]*\{[[:space:]]*\}' Sources Tests --include='*.swift' 2>/dev/null)"; then
    echo "ERROR: empty catch in Swift:"
    echo "$hits"
    fail=1
fi

# --- Force-unwrap in production Sources (tuned to exclude != / !== / prefix ! ) ---
# Matches an identifier/paren/bracket immediately followed by '!' that is not '!='.
if hits="$(grep -rnE '[[:alnum:]_)]\]?!([^=]|$)' Sources --include='*.swift' 2>/dev/null \
        | grep -vE '//' 2>/dev/null)"; then
    echo "ERROR: force-unwrap in Sources (audit or refactor):"
    echo "$hits"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "incomplete-work-scan: clean"
fi
exit "$fail"
