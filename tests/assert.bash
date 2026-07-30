# shellcheck shell=bash
# Assertions for the resumer suite.
#
# ── Why this file exists ─────────────────────────────────────────────
#
# Measured on this machine's /bin/bash (3.2.57), which is a supported tier:
#
#   `[[ 1 == 2 ]]` mid-function under set -e  -> does NOT abort. Inert.
#   negated `! true` under set -e            -> does NOT abort. Inert.
#   `[ 1 = 2 ]` mid-function under set -e    -> DOES abort. Decisive.
#
# (The negation line is written that way on purpose: a comment of `#` then spaces
# then a bare `!` is parsed by shellcheck as a malformed shebang, SC1115/SC1128.)
#
# `[[` is a compound command and bash 3.2 does not apply errexit to it inside a
# function; `[` is an ordinary builtin, so errexit does apply. That is why this
# suite's `[ "$output" = "spend" ]` assertions were always load-bearing and were
# left alone, while its seven `[[ ]]` ones could not fail and are now function
# calls.
#
# A failing function call aborts on 3.2 as well, which is what makes wrapping the
# fix rather than a style preference.
#
# Argument order is (actual, expected), matching tmux-toolkit/tests/assert.bash.

# $status and $output are set by bats' `run`, so shellcheck cannot see the
# assignment. Declared here rather than disabled at every call site.
# shellcheck disable=SC2154
_afail() { printf 'assertion failed: %s\n' "$*" >&2; return 1; }

assert_eq()       { [ "$1" = "$2" ] || _afail "expected '$2', got '$1'"; }
assert_ne()       { [ "$1" != "$2" ] || _afail "expected anything but '$2'"; }
assert_empty()    { [ -z "$1" ] || _afail "expected empty, got '$1'"; }
assert_not_empty() { [ -n "$1" ] || _afail "expected a value, got empty"; }
assert_file()     { [ -f "$1" ] || _afail "no such file: $1"; }
refute_file()     { [ ! -f "$1" ] || _afail "file should not exist: $1"; }

assert_contains() { [[ "$1" == *"$2"* ]] || _afail "'$1' does not contain '$2'"; }
refute_contains() { [[ "$1" != *"$2"* ]] || _afail "'$1' unexpectedly contains '$2'"; }

# Glob compare: $2 is deliberately unquoted, which is what makes it a pattern.
# shellcheck disable=SC2053
assert_match()    { [[ "$1" == $2 ]] || _afail "'$1' does not match glob '$2'"; }
# shellcheck disable=SC2053
refute_match()    { [[ "$1" != $2 ]] || _afail "'$1' unexpectedly matches glob '$2'"; }

# `! cmd` has the same bash 3.2 problem as a bare [[ ]].
refute() { if "$@"; then _afail "expected '$*' to fail"; fi; }
