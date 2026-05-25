#!/usr/bin/env bash
# pipeline-compound-quality.sh — Compound quality dispatch functions.
# Canonical home for stage_compound_quality and related compound quality logic.
# Currently sources pipeline-stages-review.sh (canonical) and pipeline-intelligence.sh
# (fallback) for backward compatibility.
set -euo pipefail
[[ -n "${_PIPELINE_COMPOUND_QUALITY_LOADED:-}" ]] && return 0
_PIPELINE_COMPOUND_QUALITY_LOADED=1

_PCQ_DIR="$(dirname "${BASH_SOURCE[0]}")"
# pipeline-stages-review.sh provides the canonical stage_compound_quality
# shellcheck source=pipeline-stages-review.sh
[[ -n "${_PIPELINE_STAGES_REVIEW_LOADED:-}" ]] || { [[ -f "$_PCQ_DIR/pipeline-stages-review.sh" ]] && source "$_PCQ_DIR/pipeline-stages-review.sh"; }
# Fallback: pipeline-intelligence.sh provides stage_compound_quality under its guard
# shellcheck source=pipeline-intelligence.sh
[[ -n "${_PIPELINE_INTELLIGENCE_LOADED:-}" ]] || { [[ -f "$_PCQ_DIR/pipeline-intelligence.sh" ]] && source "$_PCQ_DIR/pipeline-intelligence.sh"; }
