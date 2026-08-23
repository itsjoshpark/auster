#!/bin/bash
# Tests for render-notes.sh. Run directly: Scripts/release/render-notes.test.sh
#
# Requires cmark-gfm: brew install cmark-gfm

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
render="$script_dir/render-notes.sh"

failures=0
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

check() {
    local description="$1" condition="$2"
    if [[ "$condition" == "pass" ]]; then
        echo "ok       $description"
    else
        echo "FAIL     $description"
        failures=$((failures + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        check "$description" pass
    else
        check "$description" fail
    fi
}

write_notes() {
    local path="$workdir/notes.md"
    printf '%s' "$1" >"$path"
    echo "$path"
}

reject() {
    local description="$1" contents="$2"
    if "$render" "$(write_notes "$contents")" >/dev/null 2>&1; then
        check "$description" fail
    else
        check "$description" pass
    fi
}

# --- happy path -------------------------------------------------------------
notes="$(write_notes '- New: **Selective sync**, see [the docs](https://example.com)
- Fixed: A thing

**Note**: The index rebuilds on first launch.
')"

if result="$("$render" "$notes" 2>&1)"; then
    check "exits zero on valid Markdown" pass
else
    check "exits zero on valid Markdown" fail
    result=""
fi

assert_contains "$result" "<ul>" "renders a bullet list"
assert_contains "$result" "<li>New: " "renders list items"
assert_contains "$result" "<strong>Selective sync</strong>" "renders bold"
assert_contains "$result" '<a href="https://example.com">the docs</a>' "renders links"
assert_contains "$result" "<p><strong>Note</strong>: The index rebuilds on first launch.</p>" "renders paragraphs"

# The GitHub-flavored constructs, which plain CommonMark leaves as literal text.
gfm="$("$render" "$(write_notes '| Menu item | Does |
| --- | --- |
| Rebuild Index | Derives the index again |

- [x] New: A thing
- Fixed: ~~almost~~ everything
')")"
assert_contains "$gfm" "<table>" "renders tables"
assert_contains "$gfm" "<th>Menu item</th>" "renders table headers"
assert_contains "$gfm" '<input type="checkbox" checked="" disabled="" />' "renders task lists"
assert_contains "$gfm" "<del>almost</del>" "renders strikethrough"

# The fragment is dropped into the appcast's CDATA at that indentation.
if [[ "$(grep -c '^      <' <<<"$result")" == "$(grep -c '^ *<' <<<"$result")" ]]; then
    check "indents every rendered line six spaces" pass
else
    check "indents every rendered line six spaces" fail
fi

if grep -q '[[:space:]]$' <<<"$result"; then
    check "leaves no trailing whitespace" fail
else
    check "leaves no trailing whitespace" pass
fi

# The rendered fragment is embedded in the appcast, which append-appcast-item.sh
# then validates as XML.
assert_well_formed() {
    local fragment="$1" description="$2"
    local wrapped="$workdir/wrapped.xml"
    printf '<root>\n%s\n</root>\n' "$fragment" >"$wrapped"
    if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$wrapped" 2>/dev/null; then
        check "$description" pass
    else
        check "$description" fail
    fi
}

assert_well_formed "$result" "produces well-formed markup"
assert_well_formed "$gfm" "produces well-formed markup for tables and task lists"

# A raw ]]> would close the appcast's CDATA section early. Nothing rejects one
# here because nothing has to: the '>' is escaped in text and percent-encoded in
# URLs, so it cannot reach the output. This holds cmark-gfm to that.
cdata="$("$render" "$(write_notes '- Fixed: A crash on ]]> in a filename
- Fixed: A [broken link](https://example.com/]]>)
')")"
assert_contains "$cdata" "]]&gt;" "escapes a CDATA terminator in text"
if grep -qF ']]>' <<<"$cdata"; then
    check "never emits a raw CDATA terminator" fail
else
    check "never emits a raw CDATA terminator" pass
fi

# --- guards -----------------------------------------------------------------
reject "rejects raw HTML block tags" '<ul><li>New: A thing</li></ul>'
reject "rejects raw HTML inline tags" '- New: A <b>thing</b>'
reject "rejects an empty file" ''
reject "rejects a whitespace-only file" '   '
reject "rejects a fenced code block" '```
xcodebuild
```'
reject "rejects a wholly indented file" '      - New: A thing
      - Fixed: Another
'

if "$render" "$workdir/missing.md" >/dev/null 2>&1; then
    check "rejects a missing file" fail
else
    check "rejects a missing file" pass
fi

if "$render" >/dev/null 2>&1; then
    check "rejects a missing argument" fail
else
    check "rejects a missing argument" pass
fi

# The committed template is what the workflow refuses to release with, but it
# still has to render — the archived notes of every release start from it.
if "$render" "$script_dir/../../.sparkle/notes/TEMPLATE.md" >/dev/null 2>&1; then
    check "renders the committed notes template" pass
else
    check "renders the committed notes template" fail
fi

echo
if ((failures > 0)); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
