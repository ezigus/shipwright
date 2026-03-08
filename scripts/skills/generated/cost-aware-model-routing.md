## Cost-Aware Model Routing

Implement intelligent model selection based on task complexity to reduce pipeline costs 30-50% without sacrificing success rate.

### Complexity Classification Heuristics

**Simple Tasks** (route to Haiku)
- Single file edits (1-2 files touched)
- Script generation or template filling
- Documentation updates
- Total change size: <50 lines
- No architecture decisions required

**Medium Tasks** (route to Sonnet)
- Multi-file refactors with clear scope (3-5 files)
- Feature additions within existing patterns
- Bug fixes spanning multiple components
- Total change size: 50-200 lines
- Some interdependency analysis needed

**Complex Tasks** (route to Opus)
- Architecture redesigns or major refactors
- Multi-component decisions requiring reasoning
- New patterns or abstractions
- Deep dependency analysis needed
- Total change size: >200 lines OR involves 6+ files
- Error context suggests systemic issues

### Routing Implementation

1. **Intake Phase**: Analyze task scope and extract signals
   - File count and change magnitude
   - Error complexity (simple syntax vs logical reasoning)
   - Dependency depth (isolated vs cross-cutting)
   - Architecture keywords in description

2. **Classification**: Apply weighted scoring
   ```
   score = (file_count * 0.3) + (line_changes / 100 * 0.3) + (error_complexity * 0.2) + (dependency_depth * 0.2)
   ```
   - score < 3 → Simple (Haiku)
   - 3 ≤ score < 6 → Medium (Sonnet)
   - score ≥ 6 → Complex (Opus)

3. **Override Mechanism**: Allow per-stage configuration
   - Config file: `config/policy.json` with stage-specific model tiers
   - Environment override: `FORCE_MODEL=opus` for emergency cases
   - Uncertainty threshold: If confidence < 0.7, route to next tier up

### A/B Testing Framework

- **Control**: Always use Opus (baseline cost and success rate)
- **Experimental**: Use routed models per classifier
- **Metrics**: Cost per task, success rate, error rate, time-to-completion
- **Sample size**: Minimum 100 tasks per variant for statistical significance
- **Statistical test**: χ² for success rates; t-test for cost differences
- **Success criteria**: Cost savings >25% with <2% success rate regression (p < 0.05)

### Integration Points

- **Cost tracking**: Log actual model used and cost to `~/.shipwright/costs.json`
- **Budget enforcement**: Honor both total budget AND per-model-tier budgets
- **Configuration**: Load overrides from `.claude/daemon-config.json` and stage gates
- **Monitoring**: Expose metrics to `shipwright cost show` and dashboards
- **Audit log**: Record every routing decision with rationale for analysis

### Validation Checklist

- [ ] Classifier accuracy: >85% agreement with human complexity assessment on sample
- [ ] Cost savings: Achieve projected 30-50% on routed tasks
- [ ] Success rate: No regression >2% for Haiku-routed tasks
- [ ] Edge cases: Handle ambiguous, mixed-complexity tasks gracefully
- [ ] Configuration: Overrides work without race conditions or data corruption
- [ ] Documentation: Heuristics, examples, and override syntax documented with rationale
