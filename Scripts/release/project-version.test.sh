#!/bin/bash
# Tests for project-version.sh. Run directly: Scripts/release/project-version.test.sh

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/project-version.sh"
repo_root="$(cd "$script_dir/../.." && pwd)"

failures=0
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

check() {
    if [[ "$2" == "pass" ]]; then
        echo "ok       $1"
    else
        echo "FAIL     $1"
        failures=$((failures + 1))
    fi
}

expect_equal() {
    local got="$1" want="$2" description="$3"
    if [[ "$got" == "$want" ]]; then
        check "$description" pass
    else
        check "$description (got '$got', want '$want')" fail
    fi
}

# Mirrors Config/Shared.xcconfig: one definition of each, at project level, with
# comments and neighbouring settings around them.
make_xcconfig() {
    cat >"$1" <<'XCCONFIG'
// Shared.xcconfig

SDKROOT = macosx
MACOSX_DEPLOYMENT_TARGET = 15.0

// MARK: - Versioning

MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1

// MARK: - Hygiene

DEAD_CODE_STRIPPING = YES
XCCONFIG
}

config="$workdir/Shared.xcconfig"
make_xcconfig "$config"

# --- read -------------------------------------------------------------------
expect_equal "$("$tool" read-marketing "$config")" "0.1.0" "reads the marketing version"
expect_equal "$("$tool" read-build "$config")" "1" "reads the build number"

# --- write ------------------------------------------------------------------
if "$tool" write "$config" 0.2.0 214 >/dev/null 2>&1; then
    check "exits zero on write" pass
else
    check "exits zero on write" fail
fi

expect_equal "$("$tool" read-marketing "$config")" "0.2.0" "writes the marketing version"
expect_equal "$("$tool" read-build "$config")" "214" "writes the build number"
expect_equal "$(grep -c 'DEAD_CODE_STRIPPING = YES' "$config")" "1" "leaves neighbouring settings alone"
expect_equal "$(grep -c '// MARK: - Versioning' "$config")" "1" "leaves comments alone"

# --- the real file ----------------------------------------------------------
# The workflow reads this before it does anything expensive; a rename would
# otherwise only show up mid-release.
if "$tool" read-marketing "$repo_root/Config/Shared.xcconfig" >/dev/null 2>&1 &&
    "$tool" read-build "$repo_root/Config/Shared.xcconfig" >/dev/null 2>&1; then
    check "reads the versions out of the project's own Config/Shared.xcconfig" pass
else
    check "reads the versions out of the project's own Config/Shared.xcconfig" fail
fi

# --- guards -----------------------------------------------------------------
if "$tool" read-marketing "$workdir/nope.xcconfig" >/dev/null 2>&1; then
    check "rejects a missing config file" fail
else
    check "rejects a missing config file" pass
fi

# A file whose settings are not where we expect must fail loudly rather than
# silently write nothing.
empty="$workdir/empty.xcconfig"
printf '// nothing here\n' >"$empty"
if "$tool" read-marketing "$empty" >/dev/null 2>&1; then
    check "rejects a config with no marketing version" fail
else
    check "rejects a config with no marketing version" pass
fi
if "$tool" write "$empty" 0.2.0 214 >/dev/null 2>&1; then
    check "refuses to write when the settings are absent" fail
else
    check "refuses to write when the settings are absent" pass
fi

# Two definitions mean the last one wins in an xcconfig, so a blind rewrite of
# both would be a guess about which one was authoritative.
doubled="$workdir/doubled.xcconfig"
make_xcconfig "$doubled"
printf 'MARKETING_VERSION = 9.9.9\n' >>"$doubled"
if "$tool" write "$doubled" 0.2.0 214 >/dev/null 2>&1; then
    check "refuses to write when a setting is defined twice" fail
else
    check "refuses to write when a setting is defined twice" pass
fi
if "$tool" read-marketing "$doubled" >/dev/null 2>&1; then
    check "refuses to read a setting defined twice with different values" fail
else
    check "refuses to read a setting defined twice with different values" pass
fi

# A malformed version would reach Info.plist and the appcast.
bad="$workdir/bad.xcconfig"
make_xcconfig "$bad"
if "$tool" write "$bad" "0.2" 214 >/dev/null 2>&1; then
    check "rejects a two-part marketing version" fail
else
    check "rejects a two-part marketing version" pass
fi
if "$tool" write "$bad" "0.2.0" "1.2" >/dev/null 2>&1; then
    check "rejects a non-integer build number" fail
else
    check "rejects a non-integer build number" pass
fi
expect_equal "$("$tool" read-marketing "$bad")" "0.1.0" "leaves the file untouched when validation fails"

echo
if ((failures > 0)); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
