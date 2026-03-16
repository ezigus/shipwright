# Recommendation System Design

## Similarity Matching Strategy

### Choosing TF-IDF vs Embeddings
- **TF-IDF** (recommended for MVP): Simpler, interpretable, fast to compute. Good for categorical data (issue labels, type).
- **Embeddings**: Better semantic understanding but adds model management overhead. Consider only if TF-IDF proves insufficient.

### Vector Construction
For each issue, build feature vector from:
1. Issue type (normalized categorical)
2. Labels (multi-hot encoding)
3. Title/description keywords (TF-IDF weighted, top N terms only)
4. Historical success rate by template for this issue type

Compute similarity using cosine distance; threshold at 0.6 for "similar" matches.

## Confidence Scoring Formula

```
confidence = (similar_successes / similar_total) × base_weight × sample_factor
```

Where:
- `similar_successes` = count of similar issues that succeeded with candidate template
- `similar_total` = count of all similar issues tried (any template)
- `base_weight` = template's repo-wide success rate
- `sample_factor` = clamp(similar_count / 20, 0.5, 1.0) — penalizes low sample sizes

Clamp final confidence to [0, 1].

## Edge Cases & Handling

1. **No historical data** → confidence 0.0, suggest 'standard', note "No historical patterns"
2. **Small sample** (< 5 similar) → lower confidence (×0.6), suggest anyway, note sample size
3. **All similar issues failed** → return lowest-cost template flagged "High risk"
4. **Multiple equal success** → pick lowest-cost; tie-break by recency
5. **New issue type** → use repo-wide template success rates as fallback
6. **Confidence drift** → if recommendation disagrees with outcome, log for correlation analysis

## Integration Points

**Capture on Success** (end of successful pipeline):
- Issue metadata: type, labels, title (tokenize)
- Template used, duration, cost, test count
- Store in `~/.shipwright/memory/<repo>/success-patterns.json` with timestamp

**Query on Startup** (before pipeline.start()):
- Extract metadata from issue
- Call recommendTemplate(issue_metadata)
- Return {template, confidence, rationale: "X similar issues succeeded with Y template"}
- Log user acceptance (A/B tracking)

**Track Correlation** (after pipeline completes):
- If user accepted recommendation: did it succeed?
- Update acceptance_rate and success_correlation metrics

## Performance Constraints

- Recommendation query: < 100ms (must not block pipeline startup)
- Dataset of 1000+ patterns: similarity matching stays fast (pre-compute template rates daily)
- Cache patterns in memory; refresh on new successful pipelines
- Batch update success-patterns.json (not per-pipeline write)

## Metrics to Track

1. **Acceptance rate** — % of recommendations user follows
2. **Success correlation** — % of accepted recommendations where pipeline succeeded
3. **Coverage** — % of new issues with ≥1 similar match
4. **Precision** — of accepted recs, % that led to success
5. **Confidence calibration** — do 0.9-confidence recs actually succeed ~90% of the time?
6. **Cost savings** — avg cost/duration for recommended vs non-recommended templates

## Implementation Checklist

- [ ] Schema: success-patterns.json (indexed on type, labels, template for query speed)
- [ ] Capture hook: save pattern after successful pipeline
- [ ] Similarity function: TF-IDF-based matching
- [ ] Confidence function: formula + edge case handlers
- [ ] Query API: fast lookup of similar patterns
- [ ] Metrics tracking: acceptance, correlation, coverage
- [ ] UI: display recommendation + confidence + rationale at pipeline start
- [ ] Tests: similarity accuracy, edge cases, performance benchmarks (< 100ms)
- [ ] Observability: dashboard for metrics over time; alert if confidence calibration drifts
