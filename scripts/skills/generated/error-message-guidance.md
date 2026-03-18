## Error Message Guidance: Contextual Errors with Actionable Resolution Paths

When failures occur, developers face two problems: understanding what went wrong and knowing what to do next. This skill focuses on designing error messaging systems that combine real-time context with historical patterns to provide genuine guidance.

### Core Principles

**Structure Over Volume**: Break error information into semantic sections (What Failed, Why, Historical Context, Next Actions) rather than dumping raw logs. Developers scan error output—make scannability a first-class concern.

**Pattern Matching as Guidance**: Historical failures are only valuable if the match is meaningful. Suggest actions from past failures only when the failure type, error signature, or root cause class is actually similar. Avoid noisy matches that dilute signal.

**Actionability First**: "Suggested Actions" must be concrete and applicable. Bad suggestion: "Check memory system." Good suggestion: "Run `shipwright memory show` to see if similar failures occurred; if not, collect logs with `shipwright pipeline resume --verbose`." Each action should be a copy-paste command or specific investigation step.

**Feedback Loop**: Track whether developers follow suggestions and whether those suggestions led to resolution. Use this data to tune pattern matching and prioritize high-confidence suggestions.

### Design Checklist

1. **Context Capture**: Does the error message include stage name, iteration count, original goal/issue, and elapsed time? These orient the developer immediately.

2. **Pattern Confidence**: When suggesting similar past issues, include a confidence score (e.g., "3 similar failures in the last 30 days; 67% resolved by retrying build step"). This helps developers decide whether to follow the suggestion.

3. **Log Excerpts**: Don't show raw stack traces. Extract relevant lines with 2–3 lines of context before and after the error. Highlight the specific assertion or check that failed.

4. **Escalation Path**: If pattern matching finds no similar history, suggest the next diagnostic step (e.g., "First occurrence—check logs with `shipwright pipeline artifacts show error-log`").

5. **Readability**: Use consistent formatting (dashes, indentation, section headers). Test with real errors to ensure the output is scannable at a glance.

### Common Patterns

- **Test Failure**: Suggest re-running the specific failing test first, then reviewing the test code for assumptions. Include the test name and assertion.
- **Merge Conflict**: Suggest reviewing both versions, checking `.claude/CLAUDE.md` for conventions, then running tests after resolution.
- **Resource Exhaustion**: Suggest checking memory/CPU usage, reducing parallel workers, or using `--worktree` for isolation.
- **Timeout**: Suggest increasing timeout, checking for deadlocks in logs, or breaking the task into smaller steps.

### Testing Error Messages

Error messages are code and must be tested:
- Inject synthetic failures and verify context is complete.
- Verify pattern matching returns only relevant historical suggestions.
- Test formatting with edge cases (very long error messages, special characters, missing fields).
- Measure query performance on large event logs; optimize if latency exceeds 100ms.
