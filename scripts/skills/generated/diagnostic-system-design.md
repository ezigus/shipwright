## Diagnostic System Design

### Multi-Source Data Integration
- Normalize heterogeneous sources (JSON, JSONL, markdown state, memory indexes) into a unified model
- Parse defensively: if error-summary.json is malformed, the tool degrades gracefully and uses JSONL instead
- Use type-safe parsing (e.g., jq with schema validation) to prevent cascading failures
- Log parse failures internally; don't expose raw errors to users

### Cause Ranking by Signal Strength
- **Tier 1 (exact match)**: Exact error string found in memory for the last 10 failures → confidence 0.95
- **Tier 2 (pattern match)**: Similar error pattern or stack trace substring → confidence 0.70
- **Tier 3 (stage analysis)**: The failure stage itself (e.g., test failures point to test code) → confidence 0.50
- Rank by confidence first, then by actionability (causes with clear fix paths rank higher than causes requiring investigation)

### Evidence Presentation
- For each cause, provide: file path + line number, log excerpt (3 lines max with ellipsis), related memory patterns
- Show top 3–5 causes only; too many suggestions dilute usefulness
- Format output for rapid scanning: one-liner summary, then details for each cause

### Testing Strategy
- **Synthetic failures**: Inject specific errors, truncate logs, corrupt JSON, delete memory files → verify graceful degradation
- **Ground-truth validation**: Test against 5+ known failures → did the tool suggest the actual fix in top 3 causes?
- **Performance**: Diagnose command completes in <5 seconds on large error logs (1MB+)
- **Usability testing**: Share output format with developers; refine based on feedback

### Robustness Checklist
- Empty error-summary.json → still suggest causes from JSONL + memory
- Missing error-log.jsonl → still suggest from summary + memory
- No matching memory patterns → generic suggestions based on stage + error type
- Very large logs (>10MB) → sample recent errors, summarize by frequency
