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
HAS_PROFILE_ARG=0
HAS_ROOT_ARG=0
CALLER_DIR="$PWD"

while (( $# > 0 )); do
    case "$1" in
        -y|--yes)  ASSUME_YES=1; shift ;;
        --choose)  CHOOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -p|--profile|--root)
            [[ -n "${2:-}" ]] || die "$1 needs a nonempty value"
            if [[ "$1" == --root ]]; then HAS_ROOT_ARG=1; else HAS_PROFILE_ARG=1; fi
            PASSTHROUGH+=("$1" "$2"); shift 2 ;;
        -*) die "Unknown option: $1 (see --help)" ;;
        *) [[ -n "$1" ]] || die "Profile directory must not be empty"; HAS_PROFILE_ARG=1; PASSTHROUGH+=("$1"); shift ;;
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

CURRENT_REV="$(git rev-parse HEAD)"
UPSTREAM_REV="$(git rev-parse '@{u}')"

if [[ "$CURRENT_REV" == "$UPSTREAM_REV" ]]; then
    echo "Already up to date."
elif git merge-base --is-ancestor "$UPSTREAM_REV" "$CURRENT_REV"; then
    die "Local branch is ahead of upstream; no update installed. Run ./install.sh to install your current revision."
else
    echo
    echo "New commits:"
    git --no-pager log --oneline --no-decorate "$CURRENT_REV..$UPSTREAM_REV"
    echo
    echo "Files changed:"
    git --no-pager diff --stat "$CURRENT_REV" "$UPSTREAM_REV"
    echo
    echo "Tip: these files run with full privileges inside Firefox."
    echo "     To read the changes first: git diff $CURRENT_REV $UPSTREAM_REV -- JS CSS"
    echo

    if (( ASSUME_YES == 0 )); then
        read -r -p "Apply these changes and install? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
    fi

    # Apply exactly the revision shown above, without fetching newer changes.
    if ! git merge --ff-only "$UPSTREAM_REV"; then
        echo >&2
        echo "git merge --ff-only failed. This usually means you have local edits or the" >&2
        echo "history diverged. Try: git status  (then commit, stash or reset your changes)." >&2
        exit 1
    fi
fi

# Reuse the profile from the last install unless told otherwise.
if (( CHOOSE == 0 && HAS_PROFILE_ARG == 0 && HAS_ROOT_ARG == 0 )) &&
    [[ -z "${PROFILE_ROOT:-}" ]]; then
    if saved="$(load_saved_profile)"; then
        echo
        echo "Using saved profile: $saved (pass --choose to pick another)"
        PASSTHROUGH+=(--profile "$saved")
    fi
fi

echo
echo "Installing latest version..."
cd -- "$CALLER_DIR"
exec "$SCRIPT_DIR/install.sh" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
