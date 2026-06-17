#!/bin/sh
# OpenWardRivingT developer hook installer.
#
# Pure POSIX sh. Installs the in-tree `.githooks/` hooks so the
# `commit-msg` and `pre-commit` hooks run automatically. Does not touch
# `core.hooksPath` — instead, it writes small wrapper files into the
# directory git already uses for hooks, so it chains cleanly with other
# tools (e.g. `bd`, which sets `core.hooksPath` to its own tree).
#
# Usage:
#   sh scripts/install_hooks.sh           # install (idempotent)
#   sh scripts/install_hooks.sh --uninstall
#
# The hooks are local-only (per-clone) on purpose. CI does not depend on
# them — `.github/workflows/ci.yml` runs the same checks on every push.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HOOKS_DIR="$ROOT_DIR/.githooks"
INSTALLED_MARKER="$ROOT_DIR/.githooks/.installed"

usage() {
    cat <<USAGE >&2
Usage: $0 [--uninstall | --status]
USAGE
    exit 64
}

if [ $# -gt 1 ]; then
    usage
fi

if ! command -v git >/dev/null 2>&1; then
    echo "[-] git not found in PATH." >&2
    exit 1
fi

if ! git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[-] $ROOT_DIR is not a git working tree." >&2
    exit 1
fi

# Resolve the active git hooks directory. Honour core.hooksPath when set
# (e.g. to .beads/hooks) and fall back to .git/hooks/ otherwise.
resolve_hooks_dir() {
    cfg=$(git -C "$ROOT_DIR" config --get core.hooksPath 2>/dev/null || true)
    if [ -n "$cfg" ]; then
        # core.hooksPath can be absolute or relative to the repo root.
        case "$cfg" in
            /*) printf '%s' "$cfg" ;;
            *)  printf '%s/%s' "$ROOT_DIR" "$cfg" ;;
        esac
    else
        git_dir=$(git -C "$ROOT_DIR" rev-parse --git-dir)
        case "$git_dir" in
            /*) printf '%s/hooks' "$git_dir" ;;
            *)  printf '%s/%s/hooks' "$ROOT_DIR" "$git_dir" ;;
        esac
    fi
}

ACTIVE_HOOKS_DIR=$(resolve_hooks_dir)
HOOK_NAMES="commit-msg pre-commit"

write_wrapper() {
    name=$1
    target="$HOOKS_DIR/$name"
    link="$ACTIVE_HOOKS_DIR/$name"
    cat > "$link" <<WRAPPER
#!/bin/sh
# Wrapper installed by scripts/install_hooks.sh.
# Forwards to the in-tree hook at:
#   $target
# Do not edit by hand — re-run the installer to refresh.

if [ -x "$target" ]; then
    exec "$target" "\$@"
else
    echo "[install_hooks] missing or not executable: $target" >&2
    exit 1
fi
WRAPPER
    chmod +x "$link"
    printf '    + %s -> %s\n' "$link" "$target"
}

case "${1:-}" in
    -h|--help) usage ;;
    --status)
        echo "core.hooksPath: $(git -C "$ROOT_DIR" config --get core.hooksPath 2>/dev/null || echo '<unset>')"
        echo "active hooks dir: $ACTIVE_HOOKS_DIR"
        for name in $HOOK_NAMES; do
            link="$ACTIVE_HOOKS_DIR/$name"
            if [ -f "$link" ]; then
                echo "  $name: installed (wraps $HOOKS_DIR/$name)"
            else
                echo "  $name: not installed"
            fi
        done
        exit 0
        ;;
    --uninstall)
        removed=0
        for name in $HOOK_NAMES; do
            link="$ACTIVE_HOOKS_DIR/$name"
            if [ -f "$link" ] && grep -q "scripts/install_hooks.sh" "$link" 2>/dev/null; then
                rm -f "$link"
                printf '    - %s\n' "$link"
                removed=$((removed + 1))
            fi
        done
        rm -f "$INSTALLED_MARKER"
        if [ "$removed" -eq 0 ]; then
            echo "[*] No wrappers from this installer found in $ACTIVE_HOOKS_DIR; nothing to uninstall."
        else
            echo "[*] Removed $removed wrapper(s)."
        fi
        exit 0
        ;;
    '') ;;
    *) usage ;;
esac

if [ ! -d "$HOOKS_DIR" ]; then
    echo "[-] $HOOKS_DIR does not exist." >&2
    exit 1
fi

# Ensure hook sources are executable.
for hook in "$HOOKS_DIR"/*; do
    [ -f "$hook" ] || continue
    case "$(basename "$hook")" in
        .installed) continue ;;
    esac
    if [ ! -x "$hook" ]; then
        chmod +x "$hook"
    fi
done

# Install wrappers in the active hooks directory.
mkdir -p "$ACTIVE_HOOKS_DIR"
echo "[*] Installing wrappers into $ACTIVE_HOOKS_DIR"
for name in $HOOK_NAMES; do
    if [ -f "$HOOKS_DIR/$name" ]; then
        write_wrapper "$name"
    else
        printf '    ! %s not present in .githooks/; skipping\n' "$name"
    fi
done

date -u +%Y-%m-%dT%H:%M:%SZ > "$INSTALLED_MARKER"

cat <<NEXT
[*] Done.
    core.hooksPath: $(git -C "$ROOT_DIR" config --get core.hooksPath 2>/dev/null || echo '<unset, default .git/hooks>')
    Pre-commit: shellcheck + sh -n on staged .sh, py_compile on .py,
                node --check on .js (skips app.js), JSON validation on .json.
    Commit-msg: Conventional Commits validation.
    Bypass once: git commit --no-verify
    Status:      $0 --status
    Uninstall:   $0 --uninstall
NEXT
