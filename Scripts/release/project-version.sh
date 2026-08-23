#!/bin/bash
#
# project-version.sh — read and write Auster's version settings.
#
#   project-version.sh read-marketing Config/Shared.xcconfig
#   project-version.sh read-build     Config/Shared.xcconfig
#   project-version.sh write          Config/Shared.xcconfig 0.2.0 214
#
# MARKETING_VERSION and CURRENT_PROJECT_VERSION live in Config/Shared.xcconfig,
# which every configuration of every target uses as its base — so each is
# defined exactly once. A second definition would silently win over the first,
# which is why finding one is an error rather than something to rewrite.

set -euo pipefail

die() {
    echo "project-version: $1" >&2
    exit 1
}

# One setting's value, insisting there is exactly one definition of it.
read_setting() {
    local config="$1" setting="$2"
    [[ -f "$config" ]] || die "config file not found: $config"

    local values count
    values="$(sed -n "s/^[[:space:]]*$setting[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" "$config")"
    [[ -n "$values" ]] || die "$setting not found in $config"

    count="$(wc -l <<<"$values" | tr -d ' ')"
    ((count == 1)) ||
        die "$setting is defined $count times in $config: $(tr '\n' ' ' <<<"$values")"

    echo "$values"
}

command="${1-}"
config="${2-}"

case "$command" in
    read-marketing)
        read_setting "$config" MARKETING_VERSION
        ;;

    read-build)
        read_setting "$config" CURRENT_PROJECT_VERSION
        ;;

    write)
        marketing="${3-}"
        build="${4-}"

        [[ -f "$config" ]] || die "config file not found: $config"
        [[ "$marketing" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
            die "marketing version must be X.Y.Z, got '$marketing'"
        [[ "$build" =~ ^[0-9]+$ ]] || die "build number must be a whole number, got '$build'"

        # Both must already be there, exactly once: writing into a file whose
        # layout changed would report success and change nothing.
        for setting in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
            read_setting "$config" "$setting" >/dev/null
        done

        # Written to a temp file and moved into place, so a failure cannot leave
        # a half-rewritten config behind.
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT

        sed -e "s/^\([[:space:]]*\)MARKETING_VERSION[[:space:]]*=.*$/\1MARKETING_VERSION = $marketing/" \
            -e "s/^\([[:space:]]*\)CURRENT_PROJECT_VERSION[[:space:]]*=.*$/\1CURRENT_PROJECT_VERSION = $build/" \
            "$config" >"$tmp"

        mv "$tmp" "$config"
        trap - EXIT

        echo "Set $config to $marketing ($build)"
        ;;

    "")
        die "a command is required (read-marketing, read-build, or write)"
        ;;

    *)
        die "unknown command '$command'"
        ;;
esac
