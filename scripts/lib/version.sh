#!/usr/bin/env bash
# Single source of truth for SW_VERSION. Sourced by all scripts; never hardcode version strings.
set -euo pipefail
SW_VERSION="$(jq -r .version "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)/package.json")"
export SW_VERSION
