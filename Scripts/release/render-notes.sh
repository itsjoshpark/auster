#!/bin/bash
# render-notes.sh — render Markdown release notes as an HTML fragment.
#   render-notes.sh .sparkle/notes/next.md  ->  <ul>\n<li>New: …</li>\n</ul>
# Output is indented to sit inside the appcast's <description> CDATA.

set -euo pipefail

notes="${1-}"

die() {
    echo "render-notes: $1" >&2
    exit 1
}

[[ -n "$notes" ]] || die "a Markdown notes file is required"
[[ -f "$notes" ]] || die "notes file not found: $notes"

command -v cmark-gfm >/dev/null ||
    die "cmark-gfm is not installed. Run: brew install cmark-gfm"

# The extensions GitHub itself renders, so a table is a table in both places.
# Footnotes are left off: they emit valueless attributes, HTML but not XML.
# Without --unsafe, raw HTML becomes a placeholder the tag check below catches.
html="$(cmark-gfm --to html \
    --extension table --extension tasklist \
    --extension strikethrough --extension autolink "$notes")" ||
    die "cmark-gfm could not render $notes"

if [[ "$html" == *"<!-- raw HTML omitted -->"* ]]; then
    die "$notes contains HTML tags. Release notes are Markdown — use '- item' rather than '<li>item</li>'."
fi

[[ -n "${html//[[:space:]]/}" ]] || die "$notes rendered to nothing. Write the release notes."

# Indenting a <pre> would show the indentation, and a code block here is almost
# always a line accidentally indented four spaces.
if [[ "$html" == *"<pre"* ]]; then
    die "$notes rendered a code block. Remove the fence, or the four-space indent that created one."
fi

# Blank lines are left bare, so the appcast gains no trailing whitespace.
sed 's/^./      &/' <<<"$html"
