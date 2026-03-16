## Cost Intelligence: Financial System Design for Orchestration

Build reliable cost forecasting and budget controls into distributed systems by combining historical data analysis with statistical rigor.

### Cost Model Construction
- Identify all cost vectors: model tokens (input+output), compute duration per model tier, dashboard queries, storage
- Normalize historical costs to a common currency and baseline (handle model price changes, tier differences)
- Document assumptions explicitly (e.g., cost per minute of GPT-4 vs Claude 3.5 Sonnet)

### Forecasting Algorithm
- Use template complexity and historical duration data: `cost = (stage_count × avg_duration_minutes × model_cost_per_minute) × safety_factor`
- Group historical data by template type, issue complexity band, and model selection
- Handle sparse historical data gracefully (require minimum N samples before high confidence)

### Confidence Intervals
- **High confidence**: ≥20 similar historical runs, variance coefficient <0.2, recent data (within 30 days)
- **Medium confidence**: 5–19 runs, coefficient 0.2–0.5, or older data
- **Low confidence**: <5 runs, high variance, or no comparable history
- Express forecast as: "$50–$70 (medium confidence)" not point estimates

### Budget Gating Logic
- Block pipeline start if forecast exceeds remaining daily budget by default
- Require `--force-start` override with explicit user acknowledgment
- Log gate decisions and overrides to events.jsonl for audit trail
- Warn (don't block) if forecast is 50–100% of remaining budget

### Variance Tracking
- Emit `cost_forecast_variance` events after pipeline completion: `{forecast: $50, actual: $48, confidence: "medium", template: "standard"}`
- Track accuracy metrics over time (mean absolute percentage error, coverage of confidence intervals)
- Detect when confidence intervals become miscalibrated and flag for retraining

### Dashboard Presentation
- Show forecast with confidence level when pipeline is queued: "Estimated cost: $45–$60 (medium confidence, 5 similar runs)"
- Display budget remaining and percentage of daily limit consumed
- Show warnings if run would consume >50% of remaining budget
- Include historical accuracy (e.g., "Our forecasts were within ±15% for 95% of medium-confidence runs")

### Edge Cases & Safeguards
- First pipeline run: use conservative estimate (100% of worst-case upper bound)
- Cost model changes: detect and reset confidence to low, re-baseline historical data
- Negative variance (forecast too high): may indicate optimization—track separately
- Budget threshold crossing: prefer conservative (round up) to prevent surprise overruns
