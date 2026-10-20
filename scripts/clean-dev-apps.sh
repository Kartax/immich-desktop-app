#!/bin/bash
# Unregister ImmichDesktop development copies from LaunchServices so they disappear from the
# app drawer (Launchpad / Apps), and remove ImmichDesktop's DerivedData caches.
#
# Every Xcode build registers its .app with LaunchServices, so repeated builds from the main
# checkout and from worktrees leave a grid of identical ImmichDesktop.app icons behind.
#
# Usage:
#   ./scripts/clean-dev-apps.sh                       # dry run: list what would change
#   ./scripts/clean-dev-apps.sh --apply               # unregister and delete disposable builds
#   ./scripts/clean-dev-apps.sh --apply --keep-build-artifacts
#                                                     # unregister but keep files on disk
#
# /Applications/ImmichDesktop.app is never touched.

set -euo pipefail

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APPLY=false
DELETE_BUILD_ARTIFACTS=true

usage() {
    cat <<'EOF'
Usage: scripts/clean-dev-apps.sh [--apply] [--keep-build-artifacts]

Without flags this only lists ImmichDesktop development copies registered with LaunchServices.

  --apply                  Unregister them and delete ImmichDesktop DerivedData plus registered
                           .app bundles under build/, tmp/ and .xcarchive (all regenerable).
  --keep-build-artifacts   Unregister only; keep .app bundles and DerivedData on disk.
  -h, --help               Show this help.

/Applications/ImmichDesktop.app is never touched.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --apply) APPLY=true ;;
        --keep-build-artifacts) DELETE_BUILD_ARTIFACTS=false ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $argument" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! -x "$LSREGISTER" ]]; then
    echo "LaunchServices' lsregister was not found at $LSREGISTER" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to parse the LaunchServices database" >&2
    exit 1
fi

paths_file=$(mktemp -t immichdesktop-clean-paths)
derived_file=$(mktemp -t immichdesktop-clean-derived)
trap 'rm -f "$paths_file" "$derived_file"' EXIT

parser=$(cat <<'PY'
import re
import sys

output = open(sys.argv[1], "w")
block = []

def flush():
    text = "".join(block)
    if re.search(r"^identifier:\s+org\.kartax\.ImmichDesktop\s*$", text, re.M):
        match = re.search(r"^path:\s+(.+?)(?:\s+\(0x[0-9a-fA-F]+\))?\s*$", text, re.M)
        if match:
            path = match.group(1).strip()
            if path and path != "/Applications/ImmichDesktop.app":
                output.write(path + "\n")
    block.clear()

for line in sys.stdin:
    if re.match(r"^-{20,}\s*$", line):
        flush()
    else:
        block.append(line)
flush()
output.close()
PY
)

# One path per .app registration with ImmichDesktop's bundle id, excluding the installed copy.
"$LSREGISTER" -dump 2>/dev/null | python3 -c "$parser" "$paths_file"

sort -u "$paths_file" -o "$paths_file"
count=$(wc -l < "$paths_file" | tr -d ' ')

if [[ "$count" -eq 0 ]]; then
    echo "No ImmichDesktop development copies are registered with LaunchServices."
    exit 0
fi

if "$APPLY"; then
    echo "Cleaning $count ImmichDesktop development registration(s):"
else
    echo "ImmichDesktop development registrations ($count); dry run:"
fi

while IFS= read -r path; do
    existing=""
    if [[ ! -e "$path" ]]; then
        existing=" (missing)"
    fi
    echo "  $path$existing"

    if "$APPLY"; then
        if ! "$LSREGISTER" -u "$path" >/dev/null 2>&1; then
            echo "    warning: LaunchServices could not unregister this path" >&2
        fi
    fi

    # Delete only disposable build products unless --keep-build-artifacts. An .app inside an
    # .xcarchive is removed with the whole archive, which the next release build regenerates.
    if "$DELETE_BUILD_ARTIFACTS" && [[ -e "$path" ]]; then
        case "$path" in
            *.xcarchive/*)
                archive="${path%%.xcarchive/*}.xcarchive"
                if "$APPLY"; then
                    rm -rf "$archive"
                else
                    echo "    would delete $archive"
                fi
                ;;
            */build/*|*/tmp/*|/tmp/*|/private/tmp/*)
                if "$APPLY"; then
                    rm -rf "$path"
                else
                    echo "    would delete $path"
                fi
                ;;
        esac
    fi

    # Delete the whole ImmichDesktop-<hash> DerivedData directory once.
    case "$path" in
        "$HOME/Library/Developer/Xcode/DerivedData/ImmichDesktop-"*)
            derived=${path%%/Build/*}
            if [[ -d "$derived" ]]; then
                echo "$derived" >> "$derived_file"
            fi
            ;;
    esac
done < "$paths_file"

sort -u "$derived_file" -o "$derived_file"
if [[ -s "$derived_file" ]]; then
    echo
    if "$DELETE_BUILD_ARTIFACTS"; then
        echo "ImmichDesktop DerivedData:"
    else
        echo "ImmichDesktop DerivedData (kept by --keep-build-artifacts):"
    fi
    while IFS= read -r derived; do
        echo "  $derived"
        if "$APPLY" && "$DELETE_BUILD_ARTIFACTS"; then
            rm -rf "$derived"
        fi
    done < "$derived_file"
fi

if "$APPLY"; then
    # Restart the app-drawer processes so they rebuild their icon lists from LaunchServices.
    killall Dock >/dev/null 2>&1 || true
    killall Apps >/dev/null 2>&1 || true
    pkill -f '/System/Applications/Apps.app/Contents/MacOS/Apps' >/dev/null 2>&1 || true
    echo
    echo "Done. If the drawer still shows icons, close and reopen it once."
else
    echo
    echo "Dry run only. Re-run with --apply to make these changes."
    echo "Pass --keep-build-artifacts to unregister without deleting files."
fi
