## Intake Validation & Quality Gate Design

Design validation systems that catch low-quality inputs without over-gatekeeping legitimate work.

### Scoring & Heuristics
- **Multi-factor scoring**: Combine length, structure, code references, specificity. Each factor has weight; final score is normalized 0-100.
- **Threshold design**: Default 60 is a starting point; expect to tune based on false positive rates. Document rationale for each threshold.
- **Vagueness detection**: Regex/keyword patterns for red flags ("make better", "improve", "fix") but allow when paired with specifics.
- **Code reference validation**: If issue claims to be a bug, verify files/functions exist in repo; warn on missing references.

### False Positive Mitigation
- **Exploratory work**: Score high if issue is explicitly exploratory/research-style with clear success criteria.
- **Refactor/cleanup**: Accept if scope is bounded and rationale is clear, even if description is brief.
- **Edge case handling**: Allow unusually short descriptions if they include code snippets, error logs, or reproduction steps.

### User Experience
- **Actionable feedback**: Don't just reject—list specifically what's missing ("Add acceptance criteria", "Link failing test", "Explain performance metric").
- **Feedback clarity**: Feedback should be a checklist the user can fix, not vague encouragement.
- **Allow override**: Some issues are urgent/special; provide escape hatch for gatekeepers to force-pass.

### Instrumentation
- **Event logging**: Emit validation result to events.jsonl with score, factors, and rejection reason.
- **Metrics**: Track pass/fail rates, common rejection patterns, time-to-remediation.
- **False positive measurement**: Periodically audit rejected issues to catch over-gatekeeping.
