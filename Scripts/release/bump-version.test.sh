#!/bin/bash
# Tests for bump-version.sh. Run directly: Scripts/release/bump-version.test.sh

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bump="$script_dir/bump-version.sh"

failures=0

expect() {
    local current="$1" release_type="$2" want="$3"
    local got
    got="$("$bump" "$current" "$release_type" 2>&1)"
    if [[ "$got" == "$want" ]]; then
        echo "ok       $current + $release_type -> $got"
    else
        echo "FAIL     $current + $release_type -> got '$got', want '$want'"
        failures=$((failures + 1))
    fi
}

expect_failure() {
    local current="$1" release_type="$2" description="$3"
    if "$bump" "$current" "$release_type" >/dev/null 2>&1; then
        echo "FAIL     $description: expected a non-zero exit for '$current' + '$release_type'"
        failures=$((failures + 1))
    else
        echo "ok       $description"
    fi
}

# Two-part input normalizes to three-part output.
expect "v0.1" patch "0.1.1"
expect "v0.1" minor "0.2.0"
expect "v0.1" major "1.0.0"

# Three-part input.
expect "v0.1.0" patch "0.1.1"
expect "v0.1.0" minor "0.2.0"
expect "v0.1.0" major "1.0.0"

# The "v" prefix is optional.
expect "0.1.0" minor "0.2.0"

# Minor and major bumps zero out the components below them.
expect "v1.4.7" minor "1.5.0"
expect "v1.4.7" major "2.0.0"

# Anything that would silently produce a wrong version is refused.
expect_failure "v0.1.0" "" "rejects an empty release type"
expect_failure "v0.1.0" "moderate" "rejects an unknown release type"
expect_failure "not-a-version" minor "rejects a non-numeric version"
expect_failure "v2" minor "rejects a single-component version"
expect_failure "v1.2.3.4" minor "rejects a four-component version"
expect_failure "v2.x" minor "rejects a non-numeric component"
expect_failure "" minor "rejects an empty version"

# Leading zeros are read as octal by $(( )), which fails for 08 and 09 without
# aborting the script — it would print an unbumped version and exit 0.
expect_failure "v1.08" minor "rejects a leading zero in the minor component"
expect_failure "v1.2.08" patch "rejects a leading zero in the patch component"
expect_failure "v2.09" minor "rejects 09, which is not valid octal"
expect_failure "v01.2.3" major "rejects a leading zero in the major component"

echo
if ((failures > 0)); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
