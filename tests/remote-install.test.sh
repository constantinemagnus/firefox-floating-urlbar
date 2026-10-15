#!/usr/bin/env bash
# Offline test for install-remote.sh: a stubbed curl serves a fixture repo
# archive, and stub installers record the forwarded arguments.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TEST_DIR/fixture/firefox-floating-urlbar-main" "$TEST_DIR/bin" "$TEST_DIR/tmp"
cat > "$TEST_DIR/fixture/firefox-floating-urlbar-main/install.sh" <<'INSTALL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_INSTALL_TRACE"
exit "${TEST_INSTALL_EXIT:-0}"
INSTALL
cat > "$TEST_DIR/fixture/firefox-floating-urlbar-main/uninstall.sh" <<'UNINSTALL'
#!/usr/bin/env bash
printf '%s\n' uninstall "$@" > "$TEST_INSTALL_TRACE"
exit "${TEST_INSTALL_EXIT:-0}"
UNINSTALL
chmod +x "$TEST_DIR/fixture/firefox-floating-urlbar-main/install.sh"
tar -czf "$TEST_DIR/repo.tar.gz" -C "$TEST_DIR/fixture" firefox-floating-urlbar-main
cat > "$TEST_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
while (( $# )); do
    if [[ "$1" == --output ]]; then cp "$TEST_FIXTURE_ARCHIVE" "$2"; exit; fi
    shift
done
exit 1
CURL
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH" TMPDIR="$TEST_DIR/tmp"
export TEST_FIXTURE_ARCHIVE="$TEST_DIR/repo.tar.gz" TEST_INSTALL_TRACE="$TEST_DIR/install.trace"
export FIREFOX_FLOATING_URLBAR_URL='https://example.invalid/repo.tar.gz'

bash "$REPO_DIR/install-remote.sh" --profile '/temporary profile' --firefox-dir '/temporary Firefox'
[[ "$(cat "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' --profile '/temporary profile' --firefox-dir '/temporary Firefox')" ]] ||
    fail 'remote installer did not forward arguments'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'remote installer left temporary files'

bash "$REPO_DIR/install-remote.sh" --uninstall --profile '/temporary profile'
[[ "$(cat "$TEST_INSTALL_TRACE")" == "$(printf '%s\n' uninstall --profile '/temporary profile')" ]] ||
    fail 'remote installer did not route uninstall arguments'
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'remote uninstall left temporary files'

if TEST_INSTALL_EXIT=9 bash "$REPO_DIR/install-remote.sh" --uninstall; then
    fail 'remote installer swallowed child failure'
else
    [[ "$?" == 9 ]] || fail 'remote installer changed child failure status'
fi
[[ -z "$(find "$TEST_DIR/tmp" -mindepth 1)" ]] || fail 'failed remote uninstall left temporary files'

echo 'Remote installer regressions passed (fixture archive and stubbed curl; no network).'
