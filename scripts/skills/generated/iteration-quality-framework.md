## Building an Iteration Quality Scoring Framework

When implementing iteration-level quality metrics, follow these principles:

### 1. Component Design & Normalization
- **Normalize to [0..100] Scale**: Each metric (test_delta, compile_success, error_reduction, code_churn) must map to a common scale before weighting
- **Define Bounds**: Document what constitutes excellent (80–100) vs. poor (0–20) for each component
  - test_delta: Map ±N test changes to scale; e.g., ±10 tests = 100, 0 change = 50, ±30 = 0
  - compile_success: 100 if compiles, 0 if fails (or use binary classification)
  - error_reduction: Percent reduction from baseline; account for zero-error baseline (edge case)
  - code_churn: Rate by ratio of changed lines to total lines; high churn = higher risk
- **Handle Edge Cases**: Define behavior when baseline is zero (no prior errors, no prior tests)

### 2. Weighting & Formula Justification
- **Document Derivation**: Formula (40% test_delta, 30% compile_success, 20% error_reduction, 10% code_churn) must be validated against historical iteration data
- **Compute Deterministically**: Final_Score = Σ(normalized_component × weight). Ensure reproducibility across reruns.
- **Make Weights Tunable**: If future data shows tests don't correlate with quality, reweighting should be straightforward

### 3. Threshold-Based Decision Logic
- **Define Decision Tree**:
  - score < 15: Escalate to Opus (higher reasoning, higher cost)
  - score 15–30: Adapt prompt (add examples, constraints, guidance)
  - score 30–70: Continue current strategy
  - score >= 70: Validate & accept iteration
- **Log Decisions**: Emit `escalation_triggered` or `adaptation_triggered` events to events.jsonl for audit trail
- **Cost-Aware Escalation**: Confirm that score < 15 truly indicates a stuck iteration; avoid frivolous Opus calls

### 4. Integration Points
- **Loop State**: Store score and component breakdown in loop-state.md per iteration
- **Events Log**: Emit `iteration_quality_scored` + component values; emit `escalation_triggered` when thresholds crossed
- **Dashboard**: X-axis = iteration number, Y-axis = score; overlay threshold lines (15, 30, 70); show component stacked bars for transparency

### 5. Testing & Validation
- **Historical Validation**: Apply formula to 10–20 past iterations; manually review 5 to confirm scores align with actual quality perception
- **Edge Cases**: Zero initial tests, zero initial errors, single-line changes, identical code (zero churn)
- **Boundary Testing**: Verify behavior at score exactly = 15, 30, 70
- **Regression**: Confirm loop still makes progress; escalation logic doesn't trap in infinite loop
