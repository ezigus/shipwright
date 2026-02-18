#!/usr/bin/env bash
# Updates homebrew/shipwright.rb with SHA256 hashes from the latest release.
# Usage: ./scripts/update-homebrew-sha.sh [VERSION]
#   VERSION defaults to the latest git tag (e.g. v2.4.0)
set -euo pipefail

REPO="${SHIPWRIGHT_GITHUB_REPO:-sethdford/shipwright}"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 'dev')}"
# Strip leading 'v' if present
VERSION="${VERSION#v}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA="${REPO_ROOT}/homebrew/shipwright.rb"

# Fetch checksums from the release
CHECKSUMS_URL="https://github.com/${REPO}/releases/download/v${VERSION}/checksums.txt"
echo "Downloading $CHECKSUMS_URL..."
CHECKSUMS=$(curl -sfL "$CHECKSUMS_URL") || {
    echo "ERROR: Failed to download checksums from $CHECKSUMS_URL"
    exit 1
}

sha_darwin_arm64=""
sha_darwin_x86_64=""
sha_linux_x86_64=""

while read -r line; do
    [[ -z "$line" ]] && continue
    sha="${line%% *}"
    fname="${line##* }"
    case "$fname" in
        *darwin-arm64*)    sha_darwin_arm64="$sha" ;;
        *darwin-x86_64*)   sha_darwin_x86_64="$sha" ;;
        *linux-x86_64*)    sha_linux_x86_64="$sha" ;;
    esac
done <<< "$CHECKSUMS"

# Validate we got all three
empty_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if [[ -z "$sha_darwin_arm64" || "$sha_darwin_arm64" == "$empty_hash" ]] || \
   [[ -z "$sha_darwin_x86_64" || "$sha_darwin_x86_64" == "$empty_hash" ]] || \
   [[ -z "$sha_linux_x86_64" || "$sha_linux_x86_64" == "$empty_hash" ]]; then
    echo "ERROR: Failed to extract SHA256 from checksums (darwin-arm64=${sha_darwin_arm64:-<empty>}, darwin-x86_64=${sha_darwin_x86_64:-<empty>}, linux-x86_64=${sha_linux_x86_64:-<empty>})"
    exit 1
fi

# Update formula (macOS uses sed -i '', Linux uses sed -i)
if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "s|sha256 \"PLACEHOLDER_DARWIN_ARM64_SHA256\"|sha256 \"${sha_darwin_arm64}\"|g" "$FORMULA"
    sed -i '' "s|sha256 \"PLACEHOLDER_DARWIN_X86_64_SHA256\"|sha256 \"${sha_darwin_x86_64}\"|g" "$FORMULA"
    sed -i '' "s|sha256 \"PLACEHOLDER_LINUX_X86_64_SHA256\"|sha256 \"${sha_linux_x86_64}\"|g" "$FORMULA"
else
    sed -i "s|sha256 \"PLACEHOLDER_DARWIN_ARM64_SHA256\"|sha256 \"${sha_darwin_arm64}\"|g" "$FORMULA"
    sed -i "s|sha256 \"PLACEHOLDER_DARWIN_X86_64_SHA256\"|sha256 \"${sha_darwin_x86_64}\"|g" "$FORMULA"
    sed -i "s|sha256 \"PLACEHOLDER_LINUX_X86_64_SHA256\"|sha256 \"${sha_linux_x86_64}\"|g" "$FORMULA"
fi

echo "Updated $FORMULA with SHA256 hashes for v${VERSION}:"
echo "  darwin-arm64:   ${sha_darwin_arm64}"
echo "  darwin-x86_64:  ${sha_darwin_x86_64}"
echo "  linux-x86_64:   ${sha_linux_x86_64}"
