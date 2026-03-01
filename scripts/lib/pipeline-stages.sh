#!/usr/bin/env bash
# pipeline-stages.sh — Stage implementations loader (intake, plan, build, test, review, compound_quality, pr, merge, deploy, validate, monitor) for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires all pipeline globals and state/github/detection/quality modules.
set -euo pipefail

# Module guard - prevent double-sourcing
[[ -n "${_PIPELINE_STAGES_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline}"
MODEL="${MODEL:-opus}"
BASE_BRANCH="${BASE_BRANCH:-main}"
NO_GITHUB="${NO_GITHUB:-false}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
ISSUE_BODY="${ISSUE_BODY:-}"
ISSUE_LABELS="${ISSUE_LABELS:-}"
ISSUE_MILESTONE="${ISSUE_MILESTONE:-}"
GOAL="${GOAL:-}"
TASK_TYPE="${TASK_TYPE:-feature}"
TEST_CMD="${TEST_CMD:-}"
GIT_BRANCH="${GIT_BRANCH:-}"
TASKS_FILE="${TASKS_FILE:-}"
CURRENT_STAGE_ID="${CURRENT_STAGE_ID:-}"

# ─── Load sub-modules ──────────────────────────────────────────────────────────

source "${SCRIPT_DIR}/lib/pipeline-stages-intake.sh"
source "${SCRIPT_DIR}/lib/pipeline-stages-plan-design.sh"
source "${SCRIPT_DIR}/lib/pipeline-stages-build.sh"
source "${SCRIPT_DIR}/lib/pipeline-stages-review.sh"
source "${SCRIPT_DIR}/lib/pipeline-stages-delivery.sh"
source "${SCRIPT_DIR}/lib/pipeline-stages-monitor.sh"
