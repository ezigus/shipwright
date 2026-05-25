#!/usr/bin/env bash
# pipeline-intent.sh — Intent routing functions for the pipeline.
# Canonical home for pipeline_should_skip_stage and related routing logic.
# Currently sources pipeline-intelligence.sh for backward compatibility;
# individual functions will migrate here incrementally.
set -euo pipefail
[[ -n "${_PIPELINE_INTENT_LOADED:-}" ]] && return 0
_PIPELINE_INTENT_LOADED=1

# Intent routing functions live in pipeline-intelligence.sh pending full migration.
# shellcheck source=pipeline-intelligence.sh
_PI_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -n "${_PIPELINE_INTELLIGENCE_LOADED:-}" ]] || { [[ -f "$_PI_DIR/pipeline-intelligence.sh" ]] && source "$_PI_DIR/pipeline-intelligence.sh"; }
