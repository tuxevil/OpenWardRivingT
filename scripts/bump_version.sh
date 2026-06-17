#!/bin/sh
# OpenWardRivingT version bumper.
#
# Pure POSIX sh (BusyBox ash compatible). Updates the VERSION file, refreshes
# the CHANGELOG header, and prints the next commit/tag commands. Does NOT
# commit, push, or tag — that is the maintainer's job.
#
# Usage:
#   sh scripts/bump_version.sh 0.2.0
#   sh scripts/bump_version.sh 0.2.0-rc.1    # pre-release, no header move
#   sh scripts/bump_version.sh --show        # print current version
#
# SemVer: https://semver.org/. Tag format: vX.Y.Z (vX.Y.Z-rc.N for pre-releases).

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VERSION_FILE="$ROOT_DIR/VERSION"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"

usage() {
    cat <<USAGE >&2
Usage: $0 <X.Y.Z[-(rc|alpha|beta).N]> | --show
USAGE
    exit 64
}

is_valid_semver() {
    # Match either a pre-release (X.Y.Z-<pre>.<n>) or a plain release
    # (X.Y.Z). Pre-release identifiers in {alpha, beta, rc} only.
    case "$1" in
        *-*)
            case "$1" in
                [0-9]*.[0-9]*.[0-9]*-rc.*|[0-9]*.[0-9]*.[0-9]*-alpha.*|[0-9]*.[0-9]*.[0-9]*-beta.*)
                    core=${1%%-*}
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        [0-9]*.[0-9]*.[0-9]*)
            core=$1
            ;;
        *)
            return 1
            ;;
    esac
    case "$core" in
        *.*.*.*) return 1 ;;
    esac
    # Reject leading zeros on numeric components.
    echo "$core" | awk -F. '{
        for (i = 1; i <= NF; i++) {
            if ($i !~ /^[0-9]+$/) exit 1
            if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
        }
        exit 0
    }'
}

current_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        echo "0.0.0"
    fi
}

if [ $# -ne 1 ]; then
    usage
fi

case "$1" in
    -h|--help)
        usage
        ;;
    --show)
        current_version
        exit 0
        ;;
esac

NEW_VERSION=$1
if ! is_valid_semver "$NEW_VERSION"; then
    echo "[-] '$NEW_VERSION' is not a valid SemVer identifier (X.Y.Z or X.Y.Z-<pre>.<n>)." >&2
    exit 1
fi

OLD_VERSION=$(current_version)
echo "[*] Current version: $OLD_VERSION"
echo "[*] New version:     $NEW_VERSION"

# Write VERSION atomically.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT INT TERM HUP
printf '%s\n' "$NEW_VERSION" > "$TMP"
mv -f "$TMP" "$VERSION_FILE"
trap - EXIT INT TERM HUP

# Refresh the CHANGELOG header only for a final (non pre-release) bump.
case "$NEW_VERSION" in
    *-*) ;;
    *)
        if [ -f "$CHANGELOG_FILE" ] && grep -q '^## Unreleased' "$CHANGELOG_FILE"; then
            DATE_UTC=$(date -u +%Y-%m-%d)
            awk -v ver="$NEW_VERSION" -v date="$DATE_UTC" '
                /^## Unreleased$/ {
                    print
                    print ""
                    print "## [" ver "] - " date
                    found = 1
                    next
                }
                found && /^$/ && !blank_inserted {
                    print
                    blank_inserted = 1
                    next
                }
                { print }
            ' "$CHANGELOG_FILE" > "$TMP"
            mv -f "$TMP" "$CHANGELOG_FILE"
        fi
        ;;
esac

cat <<NEXT >&2
[*] Updated $VERSION_FILE.
[*] Next steps:
    git diff VERSION CHANGELOG.md
    git add VERSION CHANGELOG.md
    git commit -m "chore(release): v$NEW_VERSION"
    git tag -s v$NEW_VERSION -m "v$NEW_VERSION"
    git push --follow-tags
NEXT
