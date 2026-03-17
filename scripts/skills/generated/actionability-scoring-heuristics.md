## Actionability Scoring Heuristics

### Scoring Model Design
Build a composable scoring system that evaluates multiple dimensions of issue quality:

**Content Quality (40 points)**
- Description length: 50+ chars = 10 points
- Specific code references or file paths: 15 points
- Acceptance criteria (explicit "Acceptance Criteria" section): 15 points

**Validation (30 points)**
- All referenced files exist in repo: 20 points
- Code references are actual functions/classes (basic grep/LSP check): 10 points

**Clarity (30 points)**
- Absence of vague language ("make better", "improve", "fix issue"): 15 points
- Presence of context/reproduction steps (for bugs): 10 points
- Problem statement is specific (not a question): 5 points

### Scoring Strategy
- Weight by dimension importance; adjust weights based on issue type (bugs require repro steps; features require acceptance criteria)
- Set threshold at 60 (tunable); provide feedback on which dimensions are low
- Emit scores and feedback to events.jsonl with issue details for future calibration
- Track false positives (low-score issues that led to successful builds) to refine heuristics

### Feedback Mechanism
When score < 60, provide:
1. Current score and dimension breakdown
2. Specific missing elements ("no acceptance criteria", "referenced file not found")
3. Example of how to improve the issue
4. Path to resubmit or escalate if the issue is actually valid
