# Implementation Plan: Intelligent Template Auto-Recommendation Engine

## Socratic Design Analysis

### Requirements Clarity

- **Minimum viable change**: When `shipwright pipeline start` runs without `--template`, analyze the repo + issue and display a recommendation with confidence score and reasoning. User can accept (default) or override. Track acceptance and outcome.
- **Implicit requirements**: The recommendation must be fast (<5s), must not break existing `--template` override, and must work offline (without Claude CLI).
- **Acceptance criteria** (from issue): recommend template with confidence + reasoning, track acceptance rate, update model from outcomes.

### Alternatives Considered

**Approach A: New standalone script `sw-recommend.sh`**

- Pros: Clean separation, standalone CLI command, testable in isolation
- Cons: Duplicates logic already in `sw-adaptive.sh` and `sw-self-optimize.sh`, another script to maintain
- Blast radius: Low (new file only) but high maintenance burden

**Approach B: Enhance existing infrastructure (CHOSEN)**

- Pros: Builds on `select_pipeline_template()`, `thompson_select_template()`, `adaptive recommend`, and `generate_reasoning_trace()` — all already exist. Minimal new code. Connects existing dots.
- Cons: Touches multiple files, but each change is small
- Blast radius: Medium — modifies existing functions but only adds new code paths

**Why Approach B**: The infrastructure for recommendation already exists in fragments across `lib/daemon-triage.sh`, `sw-self-optimize.sh`, `sw-adaptive.sh`, and `sw-pipeline.sh`. The issue is that these pieces aren't connected into a user-facing recommendation flow. We need to wire them together, add display formatting, and add tracking — not build from scratch.

### Risk Analysis

| Risk                                              | Impact                                    | Mitigation                                                                                  |
| ------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------- |
| Breaking `--template` override                    | High — users lose explicit control        | Template flag takes absolute priority; recommendation only fires when no `--template` given |
| Slow startup from recommendation                  | Medium — adds latency to `pipeline start` | Use cached intelligence data, set 5s timeout on analysis                                    |
| Inaccurate recommendations with insufficient data | Medium — misleads users                   | Show confidence level ("low" when <10 samples), default to "standard" with low confidence   |
| DB schema migration breaks existing installs      | High — corrupts pipeline tracking         | Use `IF NOT EXISTS` for new table/columns, schema version bump                              |

---

## Files to Modify

### New Files

1. **`scripts/sw-recommend.sh`** — Template recommendation engine (main logic + CLI)
2. **`scripts/sw-recommend-test.sh`** — Test suite

### Modified Files

3. **`scripts/sw-pipeline.sh`** — Hook recommendation into `pipeline_start()`, display recommendation, track acceptance
4. **`scripts/sw-db.sh`** — Add `template_recommendations` table, bump schema version
5. **`scripts/lib/daemon-triage.sh`** — Call recommendation engine from `select_pipeline_template()`
6. **`scripts/sw-adaptive.sh`** — Enhance `recommend` subcommand to use new engine
7. **`package.json`** — Register test suite

---

## Implementation Steps

### Step 1: Database Schema — `template_recommendations` table

In `sw-db.sh`, add a new table to track recommendations and their outcomes:

```sql
CREATE TABLE IF NOT EXISTS template_recommendations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT,
    issue_number TEXT,
    repo_hash TEXT,
    recommended_template TEXT NOT NULL,
    actual_template TEXT,
    confidence REAL NOT NULL DEFAULT 0.5,
    reasoning TEXT,
    factors TEXT,           -- JSON: {complexity, labels, historical_rate, repo_type}
    accepted INTEGER,       -- 1=user accepted recommendation, 0=overrode
    outcome TEXT,           -- success/failure (filled post-pipeline)
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_recommendations_repo ON template_recommendations(repo_hash);
CREATE INDEX IF NOT EXISTS idx_recommendations_template ON template_recommendations(recommended_template);
```

Bump `SCHEMA_VERSION` from 6 to 7.

### Step 2: Recommendation Engine — `sw-recommend.sh`

Core function: `recommend_template()` that combines all existing signals:

```
recommend_template(issue_json, repo_dir) → JSON {
    template: "fast",
    confidence: 0.89,
    reasoning: "89% success rate for similar issues in Node.js repos",
    factors: {
        repo_type: "node",
        complexity: "low",
        labels: ["enhancement"],
        historical_success_rates: {"fast": 0.89, "standard": 0.75, ...},
        sample_size: 42
    },
    alternatives: [
        {template: "standard", confidence: 0.75, reason: "..."},
    ]
}
```

**Signal hierarchy** (ordered by priority):

1. **Label overrides** — `hotfix`/`incident` → hotfix, `security` → enterprise (hard rules)
2. **DORA escalation** — CFR > 40% → enterprise (safety override)
3. **Quality memory** — Critical findings → enterprise (safety override)
4. **Historical success rate** — Thompson sampling from `pipeline_outcomes` table
5. **Template weights** — Learned weights from `template-weights.json`
6. **Intelligence analysis** — `recommended_template` from AI analysis
7. **Repo heuristics** — Language, framework, test setup → baseline template
8. **Fallback** — "standard" at 0.5 confidence

**Confidence scoring**:

- `sample_size >= 50` → high confidence (0.8-1.0)
- `sample_size >= 10` → medium confidence (0.5-0.8)
- `sample_size < 10` → low confidence (0.3-0.5)
- No data → minimum confidence (0.3), use heuristics only

**CLI interface**:

```bash
shipwright recommend [--issue N] [--goal "..."] [--json]
```

### Step 3: Display in Pipeline Start

In `pipeline_start()` in `sw-pipeline.sh`, after `generate_reasoning_trace()`:

```
╭─────────────────────────────────────────────╮
│  Template Recommendation                    │
│                                             │
│  ✦ fast (89% confidence)                    │
│    89% success rate for similar issues       │
│    Based on 42 historical runs              │
│                                             │
│  Override: --template <name>                │
╰─────────────────────────────────────────────╝
```

Logic:

- If `--template` was explicitly passed → skip recommendation, use specified template
- If no `--template` → run recommendation, display it, use recommended template
- Record whether recommendation was accepted (user didn't override) or rejected

### Step 4: Outcome Tracking

After pipeline completes (in existing `optimize_analyze_outcome` flow or pipeline completion handler):

- Update `template_recommendations` row with `outcome = success/failure` and `actual_template`
- This feeds back into Thompson sampling for future recommendations

### Step 5: Acceptance Rate Reporting

Add `shipwright recommend stats` subcommand:

```
Template Recommendation Stats (last 30 days)
─────────────────────────────────────────────
Acceptance rate:  78% (39/50 recommendations accepted)
Success when accepted:  92% (36/39)
Success when overridden:  73% (8/11)

Per-template accuracy:
  fast        92% success (24 runs, 87% confidence avg)
  standard    85% success (18 runs, 72% confidence avg)
  full        78% success (6 runs, 65% confidence avg)
  hotfix      100% success (2 runs, 95% confidence avg)
```

### Step 6: Wire Into Daemon Triage

In `select_pipeline_template()` in `lib/daemon-triage.sh`, add a call to `recommend_template()` as an additional signal source. The daemon already has auto-template logic; the recommendation engine provides better signal.

### Step 7: Test Suite

`sw-recommend-test.sh` — 20+ tests covering:

**Unit tests (14)**:

- Recommendation with no historical data → "standard" at low confidence
- Recommendation with strong historical data → highest success rate template
- Label override takes precedence (hotfix, security, incident)
- DORA escalation overrides recommendation
- Quality memory overrides recommendation
- Confidence scoring: high/medium/low based on sample size
- Repo type detection (node, python, go, etc.)
- JSON output format validation
- Recommendation with intelligence analysis available
- Recommendation caching (same issue returns cached result)
- Acceptance tracking (accepted=1 when no override)
- Acceptance tracking (accepted=0 when --template overrides)
- Stats subcommand output format
- Empty DB graceful handling

**Integration tests (4)**:

- Full pipeline start with recommendation display
- Recommendation → pipeline completion → outcome recorded
- Daemon triage uses recommendation
- `adaptive recommend` uses recommendation engine

**Edge cases (3)**:

- All templates have 0% success rate → fallback to "standard"
- Single template dominates (exploration vs exploitation)
- Concurrent recommendations don't corrupt DB

---

## Task Checklist

- [ ] Task 1: Add `template_recommendations` table to `sw-db.sh` (bump schema to v7)
- [ ] Task 2: Create `scripts/sw-recommend.sh` with core `recommend_template()` function
- [ ] Task 3: Add repo analysis helpers (language detection, complexity heuristics) to `sw-recommend.sh`
- [ ] Task 4: Add confidence scoring logic based on sample size and signal strength
- [ ] Task 5: Add formatted display output (boxed recommendation with confidence + reasoning)
- [ ] Task 6: Add CLI interface (`shipwright recommend [--issue N] [--goal "..."] [--json]`)
- [ ] Task 7: Hook recommendation into `pipeline_start()` in `sw-pipeline.sh`
- [ ] Task 8: Add acceptance tracking (detect `--template` override vs default acceptance)
- [ ] Task 9: Add outcome tracking (update recommendation record on pipeline completion)
- [ ] Task 10: Add `recommend stats` subcommand for acceptance/success rate reporting
- [ ] Task 11: Wire recommendation into `select_pipeline_template()` in daemon triage
- [ ] Task 12: Update `sw-adaptive.sh` recommend subcommand to use new engine
- [ ] Task 13: Register `sw-recommend-test.sh` in `package.json`
- [ ] Task 14: Create `sw-recommend-test.sh` test suite (20+ tests)
- [ ] Task 15: Run full test suite (`npm test`) and fix any regressions

**Dependencies**: Task 1 blocks Tasks 2-9. Task 2 blocks Tasks 6-12. Task 14 depends on Tasks 1-12.

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (14)**: Core recommendation logic, confidence scoring, signal hierarchy, label overrides, repo detection, output formatting, DB operations
- **Integration tests (4)**: Pipeline start flow, daemon triage flow, outcome tracking loop, adaptive recommend integration
- **Edge case tests (3)**: Empty data, single-template dominance, concurrent access

### Coverage Targets

- Recommendation logic: 90%+ branch coverage
- Signal hierarchy: All 8 priority levels tested
- Confidence scoring: All 4 tiers tested (high/medium/low/minimum)
- Display formatting: Validated output structure

### Critical Paths to Test

- **Happy path**: Issue with 50+ historical runs → confident recommendation → accepted → succeeds → updates model
- **Error case 1**: No DB available → graceful fallback to heuristic recommendation
- **Error case 2**: Intelligence analysis fails → skip AI signal, use remaining signals
- **Edge case 1**: Brand new repo with zero history → "standard" at 0.3 confidence with explanation
- **Edge case 2**: All templates historically fail → still recommend "standard" but flag low confidence

---

## Definition of Done

- [ ] `shipwright pipeline start --issue N` (without `--template`) shows template recommendation with confidence score and reasoning
- [ ] `--template` flag overrides recommendation (existing behavior preserved)
- [ ] Recommendation considers: repo type, issue complexity, historical success rates, labels, DORA metrics, quality memory
- [ ] Confidence score displayed: high (≥0.8), medium (0.5-0.8), low (<0.5)
- [ ] Acceptance tracked: whether user accepted or overrode the recommendation
- [ ] Outcome tracked: whether the pipeline succeeded with the recommended/chosen template
- [ ] `shipwright recommend stats` shows acceptance rate and success rate per template
- [ ] `shipwright recommend --issue N` works as standalone CLI command
- [ ] All existing tests pass (`npm test`)
- [ ] New test suite has 20+ tests with PASS/FAIL tracking
- [ ] Works offline (no Claude CLI or GitHub required for basic recommendations)
