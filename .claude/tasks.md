# Tasks — Build iteration quality scoring with adaptive prompting

## Status: In Progress
Pipeline: standard | Branch: feat/build-iteration-quality-scoring-with-ada-68

## Checklist
- [ ] Dashboard displays iteration quality sparkline (5+ data points)
- [ ] Quality scores are logged to `quality-scores.jsonl` with all 4 components
- [ ] Quality scores appear in loop-state.md at end of each iteration
- [ ] Events.jsonl contains `loop.quality_scored` events with iteration metadata
- [ ] Threshold actions triggered: score < 30 logs "prompt_adapted", < 15 logs "escalated"
- [ ] Dashboard API endpoint `/api/metrics/quality-scores` returns valid IterationQualityScore array
- [ ] Quality trend (improving/declining/stable) computed correctly for 3+ iterations
- [ ] All existing tests pass (npm test)
- [ ] New integration tests pass: quality aggregation, trend computation, visualization
- [ ] Regression tests pass: metric extraction, churn normalization
- [ ] Documentation updated: algorithm explanation, threshold behavior, troubleshooting
- [ ] **Task 1**: Create quality scores aggregation endpoint in dashboard/server.ts
- [ ] **Task 2**: Compute trend (improving/declining/stable) in backend
- [ ] **Task 3**: Extend MetricsData type with quality_scores fields
- [ ] **Task 4**: Implement fetchQualityScores() API client function
- [ ] **Task 5**: Create quality trend sparkline component
- [ ] **Task 6**: Add quality scores section to metrics view
- [ ] **Task 7**: Create quality details modal with component breakdown
- [ ] **Task 8**: Create iteration quality fixtures (5 samples)
- [ ] **Task 9**: Add backend integration test for quality aggregation

## Notes
- Generated from pipeline plan at 2026-03-08T12:14:58Z
- Pipeline will update status as tasks complete
