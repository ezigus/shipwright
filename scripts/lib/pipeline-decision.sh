#!/usr/bin/env bash
# pipeline-decision.sh — Decision scoring functions for the pipeline.
# Canonical home for classify_quality_findings, pipeline_adaptive_cycles,
# pipeline_select_audits, pipeline_reassess_complexity, pipeline_backtrack_to_stage.
# Currently sources pipeline-intelligence.sh for backward compatibility;
# individual functions will migrate here incrementally.
set -euo pipefail
[[ -n "${_PIPELINE_DECISION_LOADED:-}" ]] && return 0
_PIPELINE_DECISION_LOADED=1

# Decision scoring functions live in pipeline-intelligence.sh pending full migration.
# shellcheck source=pipeline-intelligence.sh
_PD_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -n "${_PIPELINE_INTELLIGENCE_LOADED:-}" ]] || { [[ -f "$_PD_DIR/pipeline-intelligence.sh" ]] && source "$_PD_DIR/pipeline-intelligence.sh"; }
