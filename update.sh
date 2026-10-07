#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<USAGE
Usage: ./update.sh [options]

Options:
  -y, --yes       Don't ask for confirmation before applying changes
      --choose    Pick the profile again instead of using the saved one
  -h, --help      Show this help

Other options (--profile, --root) are passed through to install.sh.
USAGE
}

ASSUME_YES=0
CHOOSE=0
PASSTHROUGH=()

while (( $# > 0 )); do
    case "$1" in
        -y|--yes)  ASSUME_YES=1; shift ;;
        --choose)  CHOOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         PASSTHROUGH+=("$1"); shift ;;
    esac
done

cd "$SCRIPT_DIR"

# Refuse to update over local edits (untracked files are ignored).
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    die "Repository has local changes. Commit or stash them before updating."
fi

echo "Checking for updates..."

git fetch --quiet || die "git fetch failed. Check your network connection and remote."

git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 ||
    die "This branch has no upstream. Run: git branch --set-upstream-to=origin/main"

if [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]]; then
    echo "Already up to date."
else
    echo
    echo "New commits:"
    git --no-pager log --oneline --no-decorate 'HEAD..@{u}'
    echo
    echo "Files changed:"
    git --no-pager diff --stat HEAD '@{u}'
    echo
    echo "Tip: these files run with full privileges inside Firefox."
    echo "     To read the changes first: git diff HEAD '@{u}' -- JS CSS"
    echo

    if (( ASSUME_YES == 0 )); then
        read -r -p "Apply these changes and install? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
    fi

    if ! git pull --ff-only; then
        echo >&2
        echo "git pull --ff-only failed. This usually means you have local edits or the" >&2
        echo "history diverged. Try: git status  (then commit, stash or reset your changes)." >&2
        exit 1
    fi
fi

# Reuse the profile from the last install unless told otherwise.
HAS_PROFILE_ARG=0
for arg in "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"; do
    case "$arg" in -p|--profile) HAS_PROFILE_ARG=1 ;; esac
done

if (( CHOOSE == 0 && HAS_PROFILE_ARG == 0 )); then
    if saved="$(load_saved_profile)"; then
        echo
        echo "Using saved profile: $saved (pass --choose to pick another)"
        PASSTHROUGH+=(--profile "$saved")
    fi
fi

echo
echo "Installing latest version..."
exec "$SCRIPT_DIR/install.sh" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
