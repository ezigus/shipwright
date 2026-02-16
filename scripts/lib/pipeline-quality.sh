# pipeline-quality.sh — Quality gate thresholds from policy (for pipeline + quality scripts)
# Source from sw-pipeline.sh or sw-quality.sh. Requires SCRIPT_DIR and policy.sh.
[[ -n "${_PIPELINE_QUALITY_LOADED:-}" ]] && return 0
_PIPELINE_QUALITY_LOADED=1

# Policy overrides when config/policy.json exists
[[ -f "${SCRIPT_DIR:-}/lib/policy.sh" ]] && source "${SCRIPT_DIR:-}/lib/policy.sh"
if type policy_get &>/dev/null 2>&1; then
    PIPELINE_COVERAGE_THRESHOLD=$(policy_get ".pipeline.coverage_threshold_percent" "60")
    PIPELINE_QUALITY_GATE_THRESHOLD=$(policy_get ".pipeline.quality_gate_score_threshold" "70")
    QUALITY_COVERAGE_THRESHOLD=$(policy_get ".quality.coverage_threshold" "70")
    QUALITY_GATE_SCORE_THRESHOLD=$(policy_get ".quality.gate_score_threshold" "70")
else
    PIPELINE_COVERAGE_THRESHOLD=60
    PIPELINE_QUALITY_GATE_THRESHOLD=70
    QUALITY_COVERAGE_THRESHOLD=70
    QUALITY_GATE_SCORE_THRESHOLD=70
fi

# Minimum quality gate threshold for non-strict mode (floor)
pipeline_quality_min_threshold() {
    echo "${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"
}
