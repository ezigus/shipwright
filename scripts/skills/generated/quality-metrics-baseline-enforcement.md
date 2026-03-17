## Quality Metrics Baseline Enforcement

Implement quality gate system that establishes baselines, detects regressions, and blocks merges when code quality degrades.

### Baseline Establishment & Storage
- Capture baseline metrics from main branch (or last successful commit)
- Store baselines durably (e.g., in `.shipwright/baselines/` directory or Git commit metadata)
- Support baseline refresh without losing regression detection capability
- Document baseline freshness - timestamp when baseline was last updated
- Handle baseline initialization for new repos (first baseline from main, or auto-create)

### Metric Collection Strategy
- **Coverage**: Parse coverage.json or test framework output; capture line/branch coverage %
- **Complexity**: Use static analysis tool (e.g., plato, complexity-report); measure cyclomatic complexity
- **Violations**: Count linting/static analysis failures by rule; distinguish new violations from pre-existing
- **Scope decision**: Changed files only vs. whole repo? (Recommend: changed files for performance)
- **New files**: Decide threshold (100% coverage? Or exempt?) to avoid blocking new development
- **Deleted files**: Don't count removal as quality improvement; track separately
- **Test-only files**: May need special handling - don't penalize test code coverage fluctuation

### Regression Detection & Gate Logic
- Compare PR tip metrics against baseline (main)
- Calculate deltas per metric: ΔCoverage (%), ΔComplexity (absolute), ΔViolations (count)
- Gate decision logic:
  - **FAIL** if coverage drops >5% (configurable)
  - **FAIL** if cyclomatic complexity increases >20% (configurable)
  - **FAIL** if new violations introduced (count increase)
  - **PASS** otherwise
- Make thresholds configurable in `.shipwright/quality-gate-config.json` or similar
- Log decision reasoning for each metric (needed for debugging false positives)

### Override Mechanism & Audit Trail
- Implement `--force-merge` flag requiring explicit justification comment
- **Justification requirements**: Non-empty, minimum length (e.g., 20 chars), human-readable
- **Audit all overrides**: Log to events.jsonl with {actor, timestamp, justification, metrics}
- **Consider approval gate**: Require @mention of maintainer or codeowner to approve override
- **Block policy circumvention**: Detect patterns (e.g., same justification reused repeatedly)

### GitHub Integration
- Post GitHub Check with conclusion: `success` (passed gate), `failure` (blocked), or `neutral` (warning-only)
- Check title: "Quality Gate: Coverage & Complexity"
- Check summary includes:
  - Coverage delta: "85.2% → 82.1% (−3.1%, threshold: 5%) ✅ PASS"
  - Complexity delta: "Avg cyclomatic: 4.2 → 5.8 (+1.6, threshold: 20%) ✅ PASS"
  - New violations: "0 new violations"
- If failed, include remediation steps in check details
- Post PR comment with quality delta table for visibility

### Edge Cases & Special Handling
- **Binary/generated files**: Exclude from metrics (e.g., dist/, build/, .min.js)
- **Documentation-only PRs**: Option to exempt from coverage gate (tag PR with `docs-only`)
- **Monorepos**: Support per-package baselines if needed
- **First PR on branch**: Consider warning-only mode (not blocking) for grace period
- **Baseline staleness**: Warn if baseline is >30 days old; require refresh

### Performance & Reliability
- Metric collection must complete in <30s (GitHub check timeout)
- Graceful degradation: If metric collection fails, emit warning check (not failure) to avoid blocking merges
- Cache baseline metrics to avoid redundant work
- Log execution time and failure reasons for observability

### Events & Observability
- Emit `quality_gate` events to events.jsonl:
  ```json
  {"type": "quality_gate", "status": "pass"|"fail", "metrics": {"coverage_delta": -3.1, "complexity_delta": 1.6, "violations_new": 0}, "override": false}
  ```
- Include metric values in event for historical analysis
- Track which gates fail most often (feedback for threshold tuning)
