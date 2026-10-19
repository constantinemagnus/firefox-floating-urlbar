#!/usr/bin/env bash
# Packages are exact snapshots of the selected commit, with no demo/test payloads.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! checkout="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" || [[ ! "$REPO_DIR" -ef "$checkout" ]]; then
    echo 'SKIP: package regressions require a Git checkout.'
    exit 0
fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
revision="$(git -C "$REPO_DIR" rev-parse HEAD)"
mkdir "$TEST_DIR/first"
printf 'stale manual archive\n' > "$TEST_DIR/first/firefox-floating-urlbar-manual.zip"
printf 'stale checksums\n' > "$TEST_DIR/first/SHA256SUMS"
bash "$REPO_DIR/packaging/build-installers.sh" "$revision" "$TEST_DIR/first" >/dev/null
bash "$REPO_DIR/packaging/build-installers.sh" "$revision" "$TEST_DIR/second" >/dev/null
for format in tar.gz zip; do
    cmp "$TEST_DIR/first/firefox-floating-urlbar.$format" "$TEST_DIR/second/firefox-floating-urlbar.$format" || fail "non-reproducible $format"
done
cmp "$TEST_DIR/first/firefox-floating-urlbar-manual.zip" "$TEST_DIR/second/firefox-floating-urlbar-manual.zip" || fail 'non-reproducible manual ZIP'
cmp "$TEST_DIR/first/SHA256SUMS" "$TEST_DIR/second/SHA256SUMS" || fail 'non-reproducible checksums'
(
    cd -- "$TEST_DIR/first"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS;
    else shasum -a 256 -c SHA256SUMS; fi
) || fail 'archive checksums are stale'
[[ "$(wc -l < "$TEST_DIR/first/SHA256SUMS" | tr -d ' ')" == 3 ]] || fail 'checksum manifest does not cover all archives'
mkdir "$TEST_DIR/extracted"
tar -xzf "$TEST_DIR/first/firefox-floating-urlbar.tar.gz" -C "$TEST_DIR/extracted"
files=(install.sh uninstall.sh lib.sh autoconfig.sh fx-autoconfig.conf install.ps1
    JS/replace-new-tab.uc.js CSS/firefox-floating-urlbar.uc.css LICENSE ATTRIBUTION.md README.md)
for file in "${files[@]}"; do
    git -C "$REPO_DIR" show "$revision:$file" > "$TEST_DIR/expected"
    cmp "$TEST_DIR/expected" "$TEST_DIR/extracted/firefox-floating-urlbar/$file" || fail "wrong packaged $file"
done
count="$(find "$TEST_DIR/extracted" -type f | wc -l | tr -d ' ')"
[[ "$count" == "${#files[@]}" ]] || fail 'package includes unrelated files'
for variant in full manual; do
    archive="$TEST_DIR/first/firefox-floating-urlbar.zip"
    prefix=firefox-floating-urlbar
    if [[ "$variant" == manual ]]; then
        archive="$TEST_DIR/first/firefox-floating-urlbar-manual.zip"
        prefix=firefox-floating-urlbar-manual
        files=(JS/replace-new-tab.uc.js CSS/firefox-floating-urlbar.uc.css LICENSE ATTRIBUTION.md README.md)
    fi
    for file in "${files[@]}"; do
        git -C "$REPO_DIR" show "$revision:$file" > "$TEST_DIR/expected"
        unzip -p "$archive" "$prefix/$file" > "$TEST_DIR/actual"
        cmp "$TEST_DIR/expected" "$TEST_DIR/actual" || fail "wrong $variant ZIP file: $file"
    done
    count="$(unzip -Z1 "$archive" | awk '!/\/$/ { n++ } END { print n+0 }')"
    [[ "$count" == "${#files[@]}" ]] || fail "$variant ZIP includes unrelated files"
done
if bash "$REPO_DIR/packaging/build-installers.sh" nonexistent-ref "$TEST_DIR/invalid" > "$TEST_DIR/error.log" 2>&1; then
    fail 'accepted invalid package revision'
fi
mkdir -p "$TEST_DIR/source-zip/tests"
cp "$REPO_DIR/tests/package.test.sh" "$TEST_DIR/source-zip/tests/"
bash "$TEST_DIR/source-zip/tests/package.test.sh" > "$TEST_DIR/source-zip.log" 2>&1 || fail 'package suite failed without Git metadata'
grep -q '^SKIP:' "$TEST_DIR/source-zip.log" || fail 'source ZIP did not explicitly skip Git-dependent tests'
echo 'Package regressions passed (committed source snapshots; no publishing).'
