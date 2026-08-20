#!/usr/bin/env bash
# Validate this plugin folder against the Omarchy plugin manifest schema.
#
# Mirrors `omarchy plugin validate` (omarchy-plugin-validate from
# https://github.com/basecamp/omarchy, MIT, Copyright (c) David Heinemeier
# Hansson) so CI can refuse to publish anything the running shell would
# silently reject without needing an Omarchy install on the runner.
#
# Usage: scripts/validate-plugin.sh [plugin-folder]
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="${1:-$repo_root}"

fail() {
  echo "validate-plugin: $*" >&2
  exit 1
}

[[ -n $PLUGIN_DIR && -d $PLUGIN_DIR ]] || fail "plugin folder not found: ${PLUGIN_DIR:-<none>}"

MANIFEST="$PLUGIN_DIR/manifest.json"
[[ -f $MANIFEST ]] || fail "missing manifest.json in $PLUGIN_DIR"
jq -e . "$MANIFEST" >/dev/null 2>&1 || fail "manifest.json is not valid JSON: $MANIFEST"

# schemaVersion must be exactly the JSON number 1 (the only version the registry
# understands). jq's == is type-aware, so the string "1" is correctly rejected
# just as the QML `schemaVersion !== 1` check rejects it.
jq -e '.schemaVersion == 1' "$MANIFEST" >/dev/null 2>&1 \
  || fail "unsupported or missing schemaVersion (expected 1) in $MANIFEST"

for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' "$MANIFEST" >/dev/null 2>&1 \
    || fail "manifest missing required field '$field'"
done

ID=$(jq -r '.id // ""' "$MANIFEST")
[[ -n $ID ]] || fail "manifest 'id' is empty"
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid plugin id '$ID'"
[[ $ID != *".."* ]] || fail "invalid plugin id '$ID'"
[[ $ID != omarchy.* ]] || fail "plugin id '$ID' uses the reserved omarchy.* namespace"

# kinds must be a non-empty array.
jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'kinds' must be a non-empty array"

# entryPoints must be an object and every value a safe relative path that exists.
jq -e '(.entryPoints | type) == "object"' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'entryPoints' must be an object"

# A bar widget may declare where it should land when enabled without an
# explicit placement.
jq -e '
  if ((.barWidget? | type) == "object" and (.barWidget | has("defaultSection"))) then
    .barWidget.defaultSection as $section
    | ($section | type) == "string"
      and (["left", "center", "right"] | index($section)) != null
  else
    true
  end
' "$MANIFEST" >/dev/null 2>&1 \
  || fail "'barWidget.defaultSection' must be left, center, or right"

# Read each entry point as a JSON-encoded string (one per line), then decode it,
# so a value that itself contains a newline stays one literal path instead of
# being split into fragments that each pass the checks.
while IFS= read -r ep_json; do
  [[ -n $ep_json ]] || continue
  ep=$(jq -r '.' <<<"$ep_json")
  [[ -n $ep ]] || fail "entry point path is empty"
  [[ $ep != *$'\n'* ]] || fail "entry point may not contain a newline"
  [[ $ep != /* ]] || fail "entry point must be a relative path: '$ep'"
  [[ $ep != *".."* ]] || fail "entry point may not contain '..': '$ep'"
  [[ -f "$PLUGIN_DIR/$ep" ]] || fail "entry point file not found: '$ep'"
done < <(jq -c '.entryPoints | to_entries[] | .value' "$MANIFEST")

# A kind is a promise to supply something to load, and the shell looks for that
# something under a fixed key: entryPoints.bar to draw a bar, entryPoints.menu
# to open a menu, and so on. Claiming a kind without its entry point is accepted
# everywhere else -- the bar falls back to the built-in, the widget is skipped --
# leaving a plugin that installs, enables, and does nothing, explained only by a
# line on the shell's console. Refuse it here, while there is still someone to
# tell.
for kind_entry_point in \
  "bar:bar" \
  "bar-widget:barWidget" \
  "menu:menu" \
  "overlay:overlay" \
  "panel:panel" \
  "service:service"; do
  kind="${kind_entry_point%%:*}"
  entry_point="${kind_entry_point##*:}"
  jq -e --arg kind "$kind" '(.kinds | index($kind)) != null' "$MANIFEST" >/dev/null 2>&1 || continue
  jq -e --arg ep "$entry_point" '.entryPoints | has($ep)' "$MANIFEST" >/dev/null 2>&1 \
    || fail "kind '$kind' requires an 'entryPoints.$entry_point' to load"
done

# Refuse any symlink anywhere inside the plugin folder. Symlinks could point a
# copied plugin back at arbitrary files on disk after it lands in the trusted
# plugins directory. The .git dir is skipped: installed plugins are git
# checkouts, and git's internals are never loaded by the shell.
link=$(find "$PLUGIN_DIR" -name .git -prune -o -type l -print -quit 2>/dev/null)
[[ -z $link ]] || fail "symlinks are not allowed inside a plugin folder: $link"

echo "validate-plugin: $PLUGIN_DIR is valid"
