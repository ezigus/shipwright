# Architecture Decision Record: Intelligent Template Auto-Recommendation Engine

**Status**: Accepted
**Date**: 2026-03-04
**Issue**: #33
**Branch**: feat/intelligent-template-auto-recommendation-33
**Decision Maker**: Senior Architect

---

## 1. Context

### Problem Statement

When users run `shipwright pipeline start` without specifying a `--template` flag, the system defaults to "standard" without analyzing the repository or issue characteristics. This misses opportunities to:

- Route simple fixes to the faster "fast" template (saving time)
- Route critical issues to "enterprise" (adding safety oversight)
- Improve user experience with transparent reasoning
- Learn from outcomes to improve recommendations over time

### Constraints

- **Performance**: Recommendation must complete in <5 seconds (doesn't block pipeline start)
- **Offline**: Must work without Claude CLI or GitHub API (for local dev + daemon mode)
- **Backward Compatibility**: Explicit `--template` flag must override recommendation without exception
- **Schema Migration**: Existing installations must not break when schema changes
- **Maintenance**: Solution must reuse existing infrastructure rather than create parallel systems

### Implicit Requirements (from Issue #33)

- Display recommendation with confidence score (high/medium/low)
- Show reasoning (why we're recommending this template)
- Track whether user accepts or overrides recommendation
- Measure acceptance rate and per-template success rates
- Feed outcomes back into recommendation model (Thompson sampling)

---

## 2. Decision

**Chosen Approach**: Wire together existing infrastructure (`select_pipeline_template()`, `thompson_select_template()`, `adaptive recommend`, `generate_reasoning_trace()`) rather than building from scratch.

### Rationale

The recommendation infrastructure already exists in fragments:

- **`lib/daemon-triage.sh`**: `select_pipeline_template()` has heuristic logic (repo type, complexity)
- **`sw-self-optimize.sh`**: `thompson_select_template()` has Bayesian sampling from historical outcomes
- **`sw-adaptive.sh`**: `recommend` subcommand shows template weights
- **`sw-pipeline.sh`**: `generate_reasoning_trace()` formats decision reasoning

**Instead of duplicating**, we create a thin orchestration layer (`sw-recommend.sh`) that:

1. Collects signals from all these sources
2. Applies a priority hierarchy (labels → DORA → quality → Thompson → weights → AI → heuristics → fallback)
3. Formats display and tracks outcomes in a new DB table
4. Integrates with pipeline start, daemon triage, and adaptive subcommands

**Signal Hierarchy** (ordered by priority/safety):

```
1. Label overrides       (hotfix/incident → hotfix; security → enterprise)
2. DORA escalation      (CFR > 40% → enterprise)
3. Quality memory       (critical findings → enterprise)
4. Thompson sampling    (historical success rates for this repo type/complexity)
5. Template weights     (learned from pipeline outcomes)
6. AI analysis          (intelligence module recommendation)
7. Repo heuristics      (language, framework, test setup)
8. Fallback             ("standard" at 0.5 confidence)
```

### Core Design Principles

- **Single Responsibility**: `sw-recommend.sh` orchestrates; existing scripts provide signals
- **Dependency Injection**: All signals passed to `recommend_template()`, not queried internally
- **Deterministic**: No random choices; use Thompson sampling for probabilistic decisions
- **Observable**: Store all recommendations + outcomes for analysis and learning
- **Graceful Degradation**: Work offline, with cached/stale data, with missing components

---

## 3. Alternatives Considered

### Alternative A: Build from Scratch

Create a new, self-contained recommendation service with its own signal analysis, confidence scoring, and outcome tracking.

**Pros**:

- Clean separation of concerns
- Easier to test in isolation
- Can use advanced ML (Bayesian networks, ensemble methods)

**Cons**:

- Duplicates logic from `sw-adaptive.sh`, `sw-self-optimize.sh`, `lib/daemon-triage.sh`
- Another 500+ LOC script to maintain
- Risk of signal divergence (recommendation engine vs. adaptive engine recommending differently)
- Higher test burden (more code to cover)

**Why Rejected**: Violates DRY principle; creates maintenance burden and signal divergence risk. Shipwright already has the infrastructure — we just need to connect it.

### Alternative B: Enhance Adaptive.sh Directly

Extend the existing `sw-adaptive.sh` to surface recommendations to CLI users.

**Pros**:

- Minimal new code (add to existing script)
- Single source of truth for template selection

**Cons**:

- `sw-adaptive.sh` is 941 LOC already (large script)
- Recommendation is a separate concern from adaptive optimization
- Daemon users need simple, fast recommendation; adaptive tuning is heavy
- Violates single responsibility (would do both optimization + recommendation + learning)

**Why Rejected**: Violates SRP. Recommendation and optimization are separate concerns with different latency budgets.

### Alternative C: Chosen — Thin Orchestration Layer

Create `sw-recommend.sh` as a lightweight orchestrator that combines signals from existing sources.

**Pros**:

- ✓ Reuses existing, tested infrastructure
- ✓ Single source of truth for each signal (adaptive has weights, self-optimize has Thompson, daemon-triage has heuristics)
- ✓ Easy to test (mock the signal sources)
- ✓ Separates concern (recommendation orchestration)
- ✓ Fast (caches results, sets timeouts)
- ✓ Maintainable (100-150 LOC orchestrator)

**Cons**:

- Touches multiple files during integration (pipeline.sh, daemon-triage.sh, adaptive.sh, db.sh)
- Requires careful DB schema design to avoid breaking existing installs

**Why Chosen**: Leverages existing infrastructure, maintains SRP, minimal maintenance burden, fast integration with daemon/pipeline.

---

## 4. Implementation Plan

### Files to Create

1. **`scripts/sw-recommend.sh`** — Recommendation engine (orchestrator + CLI)
   - Core function: `recommend_template(issue_json, repo_dir) → JSON`
   - CLI interface: `shipwright recommend [--issue N] [--goal "..."] [--json]`
   - Display formatter: `display_recommendation(recommendation_json)`
   - Signal collectors: `signal_labels()`, `signal_dora()`, `signal_quality_memory()`, etc.
   - ~150-200 LOC

2. **`scripts/sw-recommend-test.sh`** — Test suite (21 tests)
   - 14 unit tests (core logic, confidence scoring, signal hierarchy)
   - 4 integration tests (pipeline, daemon, outcome tracking, adaptive)
   - 3 edge case tests (empty data, single-template dominance, concurrent access)
   - ~400-500 LOC

### Files to Modify

3. **`scripts/sw-pipeline.sh`** — Pipeline start integration
   - After `generate_reasoning_trace()`: call `recommend_template()`
   - Display recommendation using `display_recommendation()`
   - Wrap template selection in condition: `if [[ -n "$TEMPLATE" ]]; then USE $TEMPLATE else USE recommendation`
   - After pipeline completion: update `template_recommendations` table with outcome
   - ~20-30 new lines, no deletions

4. **`scripts/sw-db.sh`** — Schema and persistence
   - Add `template_recommendations` table with SQL migration
   - Bump `SCHEMA_VERSION` from 6 to 7
   - Functions: `db_insert_recommendation()`, `db_update_recommendation_outcome()`, `db_get_recommendation_stats()`
   - ~60-80 new lines

5. **`scripts/lib/daemon-triage.sh`** — Daemon template selection
   - In `select_pipeline_template()`: call `recommend_template()` as additional signal
   - Use recommendation confidence as input to triage scoring
   - ~5-10 new lines

6. **`scripts/sw-adaptive.sh`** — Adaptive engine enhancement
   - Enhance `recommend` subcommand to delegate to `sw-recommend.sh`
   - Display per-template success rates from recommendation engine
   - ~10-15 new lines

7. **`package.json`** — Test registration
   - Add `"test:recommend": "scripts/sw-recommend-test.sh"`
   - Add to main test runner in `"test"` script
   - ~3-5 new lines

### Dependencies

- **New**: None (uses existing bash, jq, sqlite3)
- **Data**: Reads from `pipeline_outcomes` table (existing), `template-weights.json` (existing), quality memory (existing)
- **External**: Optional Claude CLI (intelligence analysis), optional GitHub API (DORA metrics via GraphQL) — graceful fallback if missing

### Risk Areas

| Risk                                           | Severity | Mitigation                                                                   |
| ---------------------------------------------- | -------- | ---------------------------------------------------------------------------- |
| Breaking `--template` override                 | High     | Explicit condition: if `--template` provided, skip recommendation            |
| Slow pipeline start from recommendation        | Medium   | Cache results (same issue within 1h), set 5s timeout on analysis             |
| DB schema migration breaks existing installs   | High     | Use `CREATE TABLE IF NOT EXISTS`, bump schema version, handle both v6 and v7 |
| Inaccurate recommendations (insufficient data) | Medium   | Display confidence tier, default to "standard" on low confidence             |
| Thompson sampling exploration vs exploitation  | Low      | Use UCB (upper confidence bound) for exploration factor                      |
| Recommendation engine itself has bugs          | Medium   | Comprehensive unit tests (14+), integration tests (4+), edge cases (3+)      |

---

## 5. Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Pipeline Start Flow                          │
│ (shipwright pipeline start --issue N [--template X])                │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
              User provided          No template flag
              --template?            provided?
                    │                             │
                   YES                           NO
                    │                             │
                    │                    ┌────────▼────────┐
                    │                    │  RECOMMENDATION │
                    │                    │ ORCHESTRATOR    │
                    │                    │ (sw-recommend)  │
                    │                    └────────┬────────┘
                    │                             │
                    │         ┌───────┬───────┬───┴────┬──────┬─────┐
                    │         │       │       │        │      │     │
           ┌────────┴─────┐   │       │       │        │      │     │
           │              │   │       │       │        │      │     │
         USE           ┌──▼───▼──┐ ┌─▼────┐┌─▼──┐ ┌──▼─┐ ┌──▼──┐┌─▼──┐
      EXPLICIT      │ Signal  │ │Label││DORA││Qual││Thom││AI  ││Heur│
      TEMPLATE      │ Priority││Override││Escal││Memory││pson││Anal││istic│
           │        │ Hierarchy││(hotfix││CFR>40││(crit││Samp││ysis││     │
           │        └──▲───▲──┘ │,sec) ││%)   ││)    ││ling││     ││     │
           │           │   │    └──────┘└─────┘└─────┘└────┘└─────┘└──────┘
           │           │   │
           │        [Signals from existing infrastructure]
           │           │   │
           │         ┌─┴───┴─┐
           │         │ Format│
           │         │ Display│
           │         └─┬─────┘
           │           │
      ┌────▼───────────▼────────┐
      │  Pipeline Execution     │
      │  (using template)       │
      └────┬────────────────────┘
           │
      ┌────▼─────────────────────┐
      │ Outcome Tracking         │
      │ Update template_          │
      │ recommendations table     │
      │ with success/failure      │
      └──────────────────────────┘
```

### Key Components

#### 1. **Signal Collection Layer** (existing infrastructure)

- `lib/daemon-triage.sh`: Repo heuristics (language, framework, test setup)
- `sw-self-optimize.sh`: Thompson sampling from `pipeline_outcomes` table
- `sw-adaptive.sh`: Template weights and AI analysis
- Daemon config: DORA metrics (CFR, lead time)
- Triage scoring: Quality memory (critical findings)

**Responsibility**: Provide signals; no recommendation logic.

**Interface**: Each signal returns value (0.0-1.0) + metadata (confidence, sample_size, reasoning).

---

#### 2. **Recommendation Orchestrator** (`sw-recommend.sh`)

Combines signals according to priority hierarchy, produces a single recommendation with confidence + reasoning.

**Responsibility**:

- Enforce signal hierarchy
- Compute confidence tier (high/medium/low)
- Format display
- Provide CLI interface

**Interface**:

```bash
# Core function
recommend_template(issue_json, repo_dir) → JSON {
    template: string,
    confidence: number (0.0-1.0),
    confidence_tier: "high"|"medium"|"low",
    reasoning: string,
    factors: {
        repo_type: string,
        complexity: "low"|"medium"|"high",
        labels: [string],
        historical_success_rates: {template: rate},
        sample_size: number
    },
    alternatives: [{template, confidence, reason}]
}

# CLI
shipwright recommend [--issue N] [--goal "..."] [--json]
shipwright recommend stats [--days 30]
```

---

#### 3. **Data Persistence Layer** (`sw-db.sh`)

Stores recommendations and outcomes for analytics and learning.

**Responsibility**:

- Create/migrate `template_recommendations` table
- Insert recommendations
- Update outcomes
- Query stats (acceptance rate, success rate)

**Interface**:

```bash
db_insert_recommendation(job_id, issue_number, repo_hash,
                         recommended_template, confidence,
                         reasoning, factors_json) → recommendation_id

db_update_recommendation_outcome(recommendation_id,
                                 actual_template, outcome, success) → void

db_get_recommendation_stats(repo_hash, days) → JSON {
    acceptance_rate: number,
    success_when_accepted: number,
    success_when_overridden: number,
    per_template: {template: {success_rate, avg_confidence, count}}
}
```

**Schema**:

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
    factors TEXT,      -- JSON
    accepted INTEGER,  -- 1=accepted, 0=overridden
    outcome TEXT,      -- "success"|"failure"
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_recommendations_repo
    ON template_recommendations(repo_hash);
CREATE INDEX IF NOT EXISTS idx_recommendations_template
    ON template_recommendations(recommended_template);
```

---

#### 4. **Pipeline Integration** (`sw-pipeline.sh`)

Hooks recommendation into pipeline start, displays to user, tracks acceptance.

**Responsibility**:

- Call recommendation engine when no `--template` provided
- Display recommendation with confidence + reasoning
- Detect whether user accepted or overrode
- Trigger outcome update after pipeline completion

**Interface**:

```bash
# Called by pipeline_start()
if [[ -z "$TEMPLATE" ]]; then
    recommendation_json=$(recommend_template "$issue_json" "$repo_dir")
    display_recommendation "$recommendation_json"
    TEMPLATE=$(echo "$recommendation_json" | jq -r '.template')
fi
```

---

#### 5. **Daemon Integration** (`lib/daemon-triage.sh`)

Uses recommendation as signal in template selection for daemon-driven pipelines.

**Responsibility**:

- Call `recommend_template()` from `select_pipeline_template()`
- Weight recommendation confidence in scoring

**Interface**:

```bash
# In select_pipeline_template()
recommendation=$(source sw-recommend.sh && recommend_template "$issue" "$repo")
confidence=$(echo "$recommendation" | jq -r '.confidence')
template=$(echo "$recommendation" | jq -r '.template')
```

---

## 6. Interface Contracts

### 1. Core Recommendation Function

```typescript
// sw-recommend.sh

interface Recommendation {
  template:
    | "fast"
    | "standard"
    | "full"
    | "hotfix"
    | "autonomous"
    | "enterprise"
    | "cost-aware";
  confidence: number; // 0.0 to 1.0
  confidence_tier: "high" | "medium" | "low"; // for UI display
  reasoning: string; // human-readable explanation
  factors: {
    repo_type: string; // "node", "python", "go", "rust", etc.
    complexity: "low" | "medium" | "high";
    labels: string[]; // issue labels that influenced decision
    historical_success_rates: Record<string, number>; // template → success %
    sample_size: number; // number of historical runs
    escalation_reason?: string; // if DORA or quality forced override
  };
  alternatives?: Array<{
    template: string;
    confidence: number;
    reason: string;
  }>;
}

function recommend_template(
  issue_json: string, // JSON { number, title, body, labels }
  repo_dir: string, // path to repo for heuristic analysis
): Recommendation;

// Error contract:
// - Missing issue_json → return Recommendation with fallback "standard" + confidence 0.3
// - Missing repo_dir → use current directory, don't fail
// - DB unavailable → continue with signal sources that don't need DB
// - Returns Recommendation always (never throws)
```

### 2. CLI Interface

```bash
# CLI Signature
shipwright recommend [OPTIONS] [SUBCOMMAND]

# OPTIONS
--issue N           # Specific issue number to analyze
--goal "..."        # Goal description (instead of issue)
--json              # Output JSON (default: human-readable)
--repo PATH         # Repository path (default: current directory)
--no-cache          # Skip cached results

# SUBCOMMANDS
stats               # Show acceptance/success rate stats
help                # Show help

# Example Usage
$ shipwright recommend --issue 33
╭─────────────────────────────────────────────╮
│  Template Recommendation                    │
│                                             │
│  ✦ fast (89% confidence)                    │
│    89% success rate for similar issues      │
│    Based on 42 historical runs              │
│                                             │
│  Override: --template <name>                │
╰─────────────────────────────────────────────╝

$ shipwright recommend --issue 33 --json
{
  "template": "fast",
  "confidence": 0.89,
  "confidence_tier": "high",
  "reasoning": "89% success rate for similar issues...",
  "factors": { ... }
}

$ shipwright recommend stats --days 30
Template Recommendation Stats (last 30 days)
─────────────────────────────────────────────
Acceptance rate:  78% (39/50 recommendations accepted)
...
```

### 3. Display Formatter

```bash
# Bash function
display_recommendation(recommendation_json: string): void

# Outputs boxed, formatted recommendation to stderr
# Example:
# ╭─────────────────────────────────────────────╮
# │  Template Recommendation                    │
# │                                             │
# │  ✦ fast (89% confidence)                    │
# │    89% success rate for similar issues      │
# │    Based on 42 historical runs              │
# │                                             │
# │  Override: --template <name>                │
# ╰─────────────────────────────────────────────╝

# Confidence tier display:
# - "high": ✓ (green checkmark)
# - "medium": ✦ (diamond, yellow)
# - "low": ⚠ (warning, orange)
```

### 4. Database Functions

```bash
# sw-db.sh

# Insert a new recommendation
db_insert_recommendation(
    job_id: string,
    issue_number: string,
    repo_hash: string,
    recommended_template: string,
    confidence: number,
    reasoning: string,
    factors_json: string           # JSON-serialized factors object
): integer;                         # returns recommendation ID

# Update recommendation with outcome
db_update_recommendation_outcome(
    recommendation_id: integer,
    actual_template: string,
    outcome: "success" | "failure"
): void;

# Get recommendation stats
db_get_recommendation_stats(
    repo_hash: string,
    days?: number              # default 30
): JSON {
    acceptance_rate: number,
    success_when_accepted: number,
    success_when_overridden: number,
    per_template: {
        [template]: {
            success_rate: number,
            avg_confidence: number,
            count: number
        }
    }
};

// Error contract:
// - DB not initialized → auto-create schema
// - Schema v6 → migrate to v7 (add table if not exists)
// - JSON parsing error → log warning, continue with defaults
// - DB locked → retry with exponential backoff (max 5 retries)
```

### 5. Signal Interface (existing functions, documented here)

```bash
# From lib/daemon-triage.sh
get_repo_heuristics(repo_dir: string): JSON {
    repo_type: string,              # "node", "python", "go", etc.
    has_tests: boolean,
    test_framework: string,
    framework: string,              # e.g., "react", "express"
    complexity_estimate: "low" | "medium" | "high"
};

# From sw-self-optimize.sh
thompson_select_template(repo_hash: string): JSON {
    template: string,
    confidence: number,
    sample_size: number,
    success_rate: number
};

# From sw-adaptive.sh
get_template_weights(): JSON {
    [template]: number              # learned weight from outcomes
};

# From DORA integration (implicit)
get_dora_metrics(): JSON {
    change_failure_rate: number,    # 0.0-1.0
    lead_time_hours: number,
    deployment_frequency_per_day: number,
    mean_time_to_recovery_hours: number
};
```

---

## 7. Data Flow

```
User runs: shipwright pipeline start --issue 33

           ┌──────────────────────────────────────┐
           │ Parse CLI args, load issue metadata  │
           └────────────┬─────────────────────────┘
                        │
                ┌───────┴────────┐
                │                │
          --template     No --template
          provided?       provided?
                │                │
              YES              NO
                │                │
              Use            ┌────▼────────────────────────┐
            explicit         │ Call recommend_template()   │
            template          │ (sw-recommend.sh)          │
                │             └────┬─────────────────────┘
                │                  │
                │         ┌────────┴──────────────┐
                │         │                       │
                │     Source: repo_dir + issue    │
                │     ├─ Repo heuristics          │
                │     │  (language, framework)    │
                │     ├─ Historical data          │
                │     │  (Thompson sampling)      │
                │     ├─ Labels                   │
                │     │  (hotfix, security)       │
                │     ├─ DORA metrics             │
                │     │  (CFR > 40% → escalate)  │
                │     ├─ Quality memory           │
                │     │  (critical findings)      │
                │     └─ Template weights         │
                │        (learned from outcomes)  │
                │                │
                │         ┌───────▼────────────┐
                │         │ Apply priority     │
                │         │ hierarchy, compute │
                │         │ confidence tier    │
                │         └────┬────────────────┘
                │              │
                │      ┌───────▼──────────┐
                │      │ Recommendation   │
                │      │ {template,       │
                │      │  confidence,     │
                │      │  reasoning,      │
                │      │  factors}        │
                │      └────┬─────────────┘
                │           │
          ┌─────┴───────────┴──────────────┐
          │  Template Selection            │
          │  (use provided or recommended) │
          └──────────┬─────────────────────┘
                     │
          ┌──────────▼──────────────┐
          │ Display recommendation  │
          │ (if not explicit)       │
          └──────────┬──────────────┘
                     │
          ┌──────────▼───────────────────────┐
          │ Insert into DB:                  │
          │ template_recommendations table   │
          │ (recommendation_id, factors,     │
          │  confidence, accepted=1)         │
          └──────────┬───────────────────────┘
                     │
          ┌──────────▼──────────────┐
          │ Execute pipeline        │
          │ using selected template │
          └──────────┬──────────────┘
                     │
          ┌──────────▼──────────────────┐
          │ Pipeline completes          │
          │ success=true/false          │
          └──────────┬──────────────────┘
                     │
          ┌──────────▼──────────────────────┐
          │ Update DB:                      │
          │ template_recommendations row    │
          │ ├─ actual_template              │
          │ ├─ outcome                      │
          │ └─ accepted (0 if overridden)   │
          └─────────────────────────────────┘
```

### Data Structures (JSON)

**Recommendation Object**:

```json
{
  "template": "fast",
  "confidence": 0.89,
  "confidence_tier": "high",
  "reasoning": "89% success rate for similar issues in Node.js repos with low complexity",
  "factors": {
    "repo_type": "node",
    "complexity": "low",
    "labels": ["enhancement"],
    "historical_success_rates": {
      "fast": 0.89,
      "standard": 0.75,
      "full": 0.6
    },
    "sample_size": 42,
    "escalation_reason": null
  },
  "alternatives": [
    {
      "template": "standard",
      "confidence": 0.75,
      "reason": "More thorough, slightly lower velocity"
    }
  ]
}
```

**Stored in DB (template_recommendations)**:

```
id | job_id | issue_number | repo_hash | recommended_template | actual_template | confidence | reasoning | factors | accepted | outcome | created_at
---|--------|--------------|-----------|----------------------|-----------------|------------|-----------|---------|----------|---------|----------
1  | job-1  | 33           | abc123    | fast                 | fast            | 0.89       | "89% ..." | {...}   | 1        | success | 2026-03-04T12:00:00Z
```

---

## 8. Error Boundaries

### Error Handling Strategy: Graceful Degradation

**Principle**: Recommendation engine should never block pipeline start. Missing data → use fallback; exceptions → log and continue.

### Component Error Responsibilities

```
┌────────────────────────────────────────────────────────────────┐
│ Layer                 │ Errors Handled                        │
├───────────────────────┼─────────────────────────────────────┤
│ Signal Collection     │ - Missing signal source              │
│ (repo heuristics,     │ - Can't detect language/framework    │
│  historical data)     │ - DB unavailable                     │
│                       │ Action: Return null signal, continue │
│                       │         with other sources           │
├───────────────────────┼─────────────────────────────────────┤
│ Recommendation Engine │ - All signals null                   │
│ (sw-recommend.sh)     │ - Confidence below threshold         │
│                       │ - Priority hierarchy deadlock        │
│                       │ Action: Return "standard" at         │
│                       │         confidence 0.3               │
├───────────────────────┼─────────────────────────────────────┤
│ Database Layer        │ - Schema mismatch (v6 vs v7)         │
│ (sw-db.sh)            │ - Table doesn't exist                │
│                       │ - Locked DB (concurrent access)      │
│                       │ - JSON parsing error                 │
│                       │ Action: Auto-migrate schema,         │
│                       │         retry with backoff,          │
│                       │         log warning and continue     │
├───────────────────────┼─────────────────────────────────────┤
│ Pipeline Integration  │ - Recommendation display fails       │
│ (sw-pipeline.sh)      │ - Outcome update fails               │
│                       │ Action: Log error, pipeline          │
│                       │         continues with recommended   │
│                       │         template                     │
└────────────────────────────────────────────────────────────────┘
```

### Specific Error Handling

**Error: Missing issue metadata**

- Signal: Issue number provided but `--goal` and title missing
- Impact: Can't analyze issue complexity
- Handling: Use repo heuristics only; reduce confidence to 0.5
- Outcome: Still produces recommendation, flags as low confidence

**Error: DB not initialized**

- Signal: First time using recommendation on this machine
- Impact: No historical data for Thompson sampling
- Handling: `db_insert_recommendation()` auto-creates schema v7
- Outcome: Thompson sampling scores 0.5 (neutral), other signals used

**Error: Schema mismatch (old v6 vs new v7)**

- Signal: Existing installation, new schema required
- Impact: Can't write to `template_recommendations` table
- Handling: `db.sh` runs `ALTER TABLE` migration, creates index
- Outcome: Transparent; user sees no breakage

**Error: DB locked (concurrent pipelines)**

- Signal: Multiple `pipeline start` calls simultaneously
- Impact: Can't insert recommendation within 5s timeout
- Handling: Retry with exponential backoff (5, 10, 20ms); log warning after 3 retries
- Outcome: Timeout → skip DB insert, still produce recommendation from signals

**Error: Thompson sampling returns NaN**

- Signal: Empty `pipeline_outcomes` table or malformed data
- Impact: Can't compute historical success rates
- Handling: Check for NaN, return 0.5 confidence for that signal
- Outcome: Other signals dominate decision

**Error: Recommendation display fails (formatting)**

- Signal: `display_recommendation()` hits error formatting boxed output
- Impact: User doesn't see recommendation, but pipeline continues
- Handling: Catch formatting error, print simple text recommendation instead
- Outcome: User sees "`Template: fast (89% confidence)`" instead of boxed format

**Error: Outcome tracking fails post-pipeline**

- Signal: Pipeline succeeded but can't update `template_recommendations.outcome`
- Impact: Lost learning signal; Thompson sampling won't improve next time
- Handling: Log error to pipeline artifacts, continue (pipeline is already done)
- Outcome: Recommendation still works; just misses one feedback sample

### Timeout Strategy

- **Recommendation computation**: 5 second timeout
  - If signals take >5s, use only signals collected so far
  - Log which signals timed out
  - Show confidence appropriately reduced

- **DB operations**: 100ms per operation, 3 retries with backoff
  - If DB locked, timeout → skip persistence, continue with signals

---

## 9. Test Pyramid Breakdown

### Test Pyramid: 21 Total Tests

```
                      △
                    /   \
                  /  E2E  \        3 tests
                /___________\      (10% - critical flows)
              /             \
            /  Integration  \      4 tests
          /___________________\    (19% - component interactions)
        /                       \
      /        Unit Tests        \  14 tests
    /_____________________________\ (67% - core logic)
```

### Unit Tests (14)

**Signal Collection & Priority Hierarchy**:

1. Label override: `hotfix` label → `hotfix` template (no consultation)
2. Label override: `security` label → `enterprise` template
3. DORA escalation: CFR > 40% → `enterprise` (overrides other signals)
4. Quality memory: critical findings → `enterprise` (safety override)
5. Thompson sampling: high success rate → template with highest success
6. Template weights: learned weights influence confidence scoring
7. Repo heuristics: Node.js repo detected → baseline template "standard"

**Confidence Scoring**: 8. High confidence: sample_size ≥ 50 → confidence 0.8-1.0 9. Medium confidence: sample_size 10-49 → confidence 0.5-0.8 10. Low confidence: sample_size < 10 → confidence 0.3-0.5 11. Minimum confidence: sample_size = 0 → confidence 0.3, use heuristics only

**Output & Formatting**: 12. JSON output: `--json` flag produces valid JSON per contract 13. Recommendation display: boxed format with emoji, confidence tier, reasoning 14. Empty/null signal handling: gracefully produces fallback recommendation

### Integration Tests (4)

1. **Pipeline Start Flow**: `pipeline start --issue 33` (no `--template`) → shows recommendation → uses recommended template
2. **Daemon Triage Integration**: `select_pipeline_template()` uses recommendation confidence as input signal
3. **Outcome Tracking Loop**: Recommendation → pipeline → outcome recorded → Thompson sampling improves
4. **Adaptive Engine Integration**: `shipwright adaptive recommend` delegates to `sw-recommend.sh`

### Edge Cases (3)

1. **Empty DB**: New installation, zero historical data → produces "standard" recommendation at confidence 0.3
2. **All Templates Fail**: 100% failure rate for all templates historically → still recommends "standard", flags low confidence with warning
3. **Concurrent Access**: Two pipelines call `recommend_template()` simultaneously → both complete without DB corruption

---

## 10. Coverage Targets

### Branch Coverage by Component

| Component                     | Target | Why                                           |
| ----------------------------- | ------ | --------------------------------------------- |
| Signal priority hierarchy     | 90%+   | 8 priority levels; all must be tested         |
| Confidence tier computation   | 95%+   | 4 tiers; must be deterministic                |
| Template selection logic      | 95%+   | Core decision path; high criticality          |
| DB operations                 | 85%+   | External dependency; some edge cases deferred |
| Display formatting            | 80%+   | UI polish; less critical than logic           |
| CLI parsing                   | 80%+   | Standard arg parsing; covered by integration  |
| Error handling/graceful degr. | 85%+   | Many fallback paths; sample all major ones    |

**Overall Target**: 85%+ branch coverage on `sw-recommend.sh`

### What NOT to Test

- Third-party command behavior (`jq`, `sqlite3` internals)
- Shell builtins (`echo`, `printf` formatting details)
- External signal computation (those are tested in their own test suites)

---

## 11. Critical Paths to Test

### Happy Path: Data-Rich Recommendation

```
Issue #33: "Add dark mode to dashboard" (label: enhancement)
Repo: Node.js project with 50+ historical template runs
DORA metrics: CFR 15%, CFR_safe=true

Expected:
- Thompson sampling: "fast" has 89% success (45/50)
- No label overrides
- DORA allows all templates
- Recommendation: "fast" at confidence 0.89
- Reasoning: "89% success rate for similar low-complexity issues"
- Outcome: User accepts (no `--template` override), pipeline succeeds
- DB: Recommendation recorded with outcome=success, accepted=1
- Next run: Thompson sampling weights updated, "fast" confidence increases
```

### Error Case 1: No Historical Data

```
Issue #42: "Refactor auth module" (label: none)
Repo: Brand new project, zero runs in this repo
DORA metrics: Not available (first pipeline)

Expected:
- Thompson sampling: No data → neutral 0.5 confidence
- Repo heuristics: TypeScript + Jest detected → "standard" baseline
- Recommendation: "standard" at confidence 0.3
- Reasoning: "Standard template recommended for new repos. Based on 0 historical runs."
- Confidence tier: "low" (flag for user awareness)
- Outcome: User accepts, pipeline succeeds
- DB: Recorded with confidence=0.3, sample_size=0
- Next run: Thompson sampling accumulates data
```

### Error Case 2: Intelligence Analysis Unavailable

```
Issue #85: "Upgrade React to v19" (label: none)
Repo: Node.js React project with 10 historical runs
Intelligence: Claude CLI not available (offline mode)

Expected:
- Intelligence signal skipped (graceful degradation)
- Other signals: Thompson, heuristics, DORA, weights all used
- Recommendation: "standard" or "full" depending on Thompson data
- Outcome: Still produces high-quality recommendation
- Performance: <5s (no Claude CLI overhead)
```

### Edge Case 1: All Templates Failed Historically

```
Repo: Hypothetical worst-case repo where every template historically failed
Issue: "Fix critical security bug" (label: security)

Expected:
- Thompson sampling: All templates show 0% success
- Label override: "security" → "enterprise" (safety)
- Recommendation: "enterprise" (forced by safety override)
- Reasoning: "Enterprise template enforced due to security label + all templates historically failed"
- Confidence: 0.3 (low, due to poor historical data)
- Warning: "Consider investigating why all templates fail in this repo"
- Outcome: Escalation to human review recommended
```

### Edge Case 2: Concurrent Recommendations

```
Two terminal windows:
  Window 1: `shipwright pipeline start --issue 100`
  Window 2: `shipwright pipeline start --issue 101`

Expected:
- Both call `db_insert_recommendation()` simultaneously
- DB lock handled with backoff retries
- Both complete within 5s timeout
- Both records persisted correctly
- No data corruption
```

### Happy Path + Acceptance Override

```
Issue #44: "Minor docs fix"
Initial recommendation: "standard" (60% confidence)
User runs: `shipwright pipeline start --issue 44 --template fast`

Expected:
- Recommendation engine skipped entirely (explicit template provided)
- Template: "fast" (explicitly specified)
- DB: template_recommendations.accepted = 0 (user rejected recommendation)
- Outcome: pipeline succeeds with "fast" template
- DB outcome: recorded with actual_template="fast", recommended_template="standard", accepted=0
- Thompson sampling: "fast" success rate increases even though not recommended
```

---

## 12. Validation Criteria

### Must Have (Definition of Done)

- [ ] `shipwright pipeline start --issue N` (without `--template`) displays template recommendation with:
  - Recommended template name
  - Confidence score (high/medium/low)
  - Human-readable reasoning
  - Note: "Override: `--template <name>`"

- [ ] Explicit `--template` flag overrides recommendation:
  - No recommendation shown
  - No recommendation computed (fast path)
  - Existing behavior fully preserved

- [ ] Recommendation considers all signals:
  - Repo type (language, framework)
  - Issue complexity (simple vs complex)
  - Historical success rates (Thompson sampling)
  - Issue labels (hotfix, security, incident)
  - DORA metrics (CFR escalation)
  - Quality memory (critical findings)

- [ ] Confidence tier displayed correctly:
  - "high" (≥0.8): Green ✓
  - "medium" (0.5-0.8): Yellow ✦
  - "low" (<0.5): Orange ⚠

- [ ] Acceptance tracked:
  - DB: `template_recommendations.accepted = 1` when recommendation used
  - DB: `template_recommendations.accepted = 0` when `--template` overrides

- [ ] Outcome tracked:
  - After pipeline: `template_recommendations.outcome = success|failure`
  - Used for Thompson sampling next run

- [ ] `shipwright recommend stats` shows:
  - Acceptance rate (% of recommendations accepted)
  - Success rate when accepted vs. when overridden
  - Per-template: success rate, avg confidence, count

- [ ] `shipwright recommend --issue N` works as standalone CLI:
  - Produces recommendation without running pipeline
  - `--json` outputs valid JSON per contract

- [ ] Works offline:
  - No Claude CLI required
  - No GitHub API required
  - Uses cached data gracefully

- [ ] All existing tests pass (`npm test`):
  - No regressions in `sw-pipeline.sh`, `sw-db.sh`, `sw-adaptive.sh`, etc.
  - New test suite: `scripts/sw-recommend-test.sh` passes (21/21)

### Nice to Have

- [ ] Recommendation caching (same issue within 1h returns cached result)
- [ ] Per-repo recommendation accuracy dashboard
- [ ] A/B testing recommendation variants (feature flag in daemon config)
- [ ] Integration with daemon auto-template selection (use recommendation as weight)

---

## 13. Success Metrics

### Code Quality

- **Coverage**: 85%+ branch coverage on `sw-recommend.sh`
- **Complexity**: McCabe complexity ≤10 for `recommend_template()`
- **Maintainability**: No function >100 LOC

### Performance

- **Latency**: Recommendation computed in <5 seconds (no impact on pipeline UX)
- **DB writes**: <50ms per insert/update
- **Memory**: <10MB for recommendation engine process

### User Experience

- **Clarity**: Recommendation reasoning understandable to non-engineers
- **Confidence**: User can explain why they accept/override recommendation
- **Transparency**: Confidence score inspires appropriate trust

### Learning

- **Acceptance rate**: >75% (recommendation quality high enough that users trust it)
- **Success when accepted**: >85% (recommendations produce successful pipelines)
- **Thompson convergence**: Confidence scores improve over time as sample size grows

---

## 14. Known Limitations & Future Work

### Current Scope (Phase 1)

- Recommendation engine wires existing signals
- Tracks acceptance + outcome
- Displays with confidence tier
- CLI command for standalone queries

### Out of Scope (Future Phases)

- Multi-repo recommendation (comparing this repo to others)
- Recommendation feature flags (A/B testing)
- Recommendation ranking (return top-3 instead of single)
- Personalization (per-developer preferences)
- Real-time recommendation feedback (user rating recommendation quality)

### Risks Mitigated by Design

- **Breaking existing behavior**: Explicit `--template` takes priority always
- **Slow pipeline start**: Cache results, 5s timeout
- **Inaccurate recommendations**: Show confidence tier, default to "standard"
- **DB corruption**: Use `IF NOT EXISTS`, auto-migrate schema
- **Maintenance burden**: Reuse existing infrastructure, thin orchestration layer

---

## Appendix: File Inventory

### New Files

- `scripts/sw-recommend.sh` (~200 LOC)
- `scripts/sw-recommend-test.sh` (~500 LOC)

### Modified Files & Impact

| File                   | Change Type                       | Lines | Risk                                                  |
| ---------------------- | --------------------------------- | ----- | ----------------------------------------------------- |
| `sw-pipeline.sh`       | Add recommendation call + display | +20   | Low (conditional, after generate_reasoning_trace)     |
| `sw-db.sh`             | Add table + schema migration      | +60   | Medium (schema change, but safe with `IF NOT EXISTS`) |
| `lib/daemon-triage.sh` | Wire recommendation into triage   | +5    | Low (optional signal, doesn't block existing logic)   |
| `sw-adaptive.sh`       | Enhance recommend subcommand      | +10   | Low (extends, doesn't break existing)                 |
| `package.json`         | Register test suite               | +3    | None                                                  |

**Total New Code**: ~700 LOC
**Total Modified Code**: ~98 LOC
**Estimated Test Time**: 5-10 seconds per run

---

## References

- Issue #33: Intelligent template auto-recommendation engine
- Related: `sw-self-optimize.sh` (Thompson sampling), `sw-adaptive.sh` (template weights), `lib/daemon-triage.sh` (heuristics)
- ADR Approved By: Senior Architect
- Implementation Lead: Engineering Team
- Date Approved: 2026-03-04
