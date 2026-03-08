// Iteration quality score rendering and analysis helpers

import { IterationQualityScore, IterationQualityTrend } from "../types/api.js";

export interface QualityScoreColor {
  bg: string;
  fg: string;
  border: string;
}

/**
 * Get color scheme for quality score based on value
 * - 0-15: critical red
 * - 15-30: warning orange
 * - 30-70: neutral yellow
 * - 70-100: success green
 */
export function getQualityScoreColor(score: number): QualityScoreColor {
  if (score < 15) {
    return {
      bg: "rgb(127, 29, 29)", // dark red
      fg: "rgb(254, 226, 226)", // light red
      border: "rgb(220, 38, 38)", // bright red
    };
  } else if (score < 30) {
    return {
      bg: "rgb(124, 45, 18)", // dark orange
      fg: "rgb(254, 237, 226)", // light orange
      border: "rgb(234, 88, 12)", // bright orange
    };
  } else if (score < 70) {
    return {
      bg: "rgb(113, 63, 18)", // dark yellow
      fg: "rgb(254, 252, 232)", // light yellow
      border: "rgb(202, 138, 4)", // bright yellow
    };
  } else {
    return {
      bg: "rgb(20, 83, 45)", // dark green
      fg: "rgb(220, 252, 231)", // light green
      border: "rgb(34, 197, 94)", // bright green
    };
  }
}

/**
 * Format quality score as percentage string with one decimal
 */
export function formatQualityScore(score: number): string {
  return score.toFixed(1);
}

/**
 * Get human-readable label for quality score
 */
export function getQualityScoreLabel(score: number): string {
  if (score < 15) {
    return "Critical";
  } else if (score < 30) {
    return "Poor";
  } else if (score < 50) {
    return "Fair";
  } else if (score < 70) {
    return "Good";
  } else if (score < 85) {
    return "Very Good";
  } else {
    return "Excellent";
  }
}

/**
 * Compute trend direction between two scores
 */
export function computeTrend(
  previous: number | undefined,
  current: number,
): "improving" | "declining" | "stable" {
  if (previous === undefined) {
    return "stable";
  }

  const diff = current - previous;
  if (Math.abs(diff) < 3) {
    return "stable";
  } else if (diff > 0) {
    return "improving";
  } else {
    return "declining";
  }
}

/**
 * Get trend emoji
 */
export function getTrendEmoji(
  trend: "improving" | "declining" | "stable",
): string {
  switch (trend) {
    case "improving":
      return "📈";
    case "declining":
      return "📉";
    case "stable":
      return "➡️";
  }
}

/**
 * Format component score breakdown
 */
export function formatComponentBreakdown(
  components?: IterationQualityScore["components"],
): string {
  if (!components) {
    return "No component data";
  }

  return (
    `test_delta: ${components.test_delta.toFixed(0)}, ` +
    `compile: ${components.compile_success.toFixed(0)}, ` +
    `error_reduction: ${components.error_reduction.toFixed(0)}, ` +
    `churn: ${components.code_churn.toFixed(0)}`
  );
}

/**
 * Determine if quality score should trigger adaptive actions
 */
export function shouldAdaptPrompt(score: number): boolean {
  return score < 30;
}

/**
 * Determine if quality score should trigger model escalation
 */
export function shouldEscalateModel(score: number): boolean {
  return score < 15;
}

/**
 * Compute average quality score from a list
 */
export function computeAverageQuality(scores: IterationQualityScore[]): number {
  if (scores.length === 0) {
    return 0;
  }

  const sum = scores.reduce((acc, s) => acc + s.quality_score, 0);
  return sum / scores.length;
}

/**
 * Compute quality score trend over last N iterations
 */
export function computeQualityTrendLine(
  scores: IterationQualityScore[],
  windowSize: number = 5,
): { slope: number; trend: "improving" | "declining" | "stable" } {
  if (scores.length < 2) {
    return { slope: 0, trend: "stable" };
  }

  // Use last N scores
  const window = scores.slice(-Math.min(windowSize, scores.length));

  // Simple linear regression
  const n = window.length;
  let sumX = 0;
  let sumY = 0;
  let sumXY = 0;
  let sumX2 = 0;

  for (let i = 0; i < n; i++) {
    const x = i + 1;
    const y = window[i].quality_score;
    sumX += x;
    sumY += y;
    sumXY += x * y;
    sumX2 += x * x;
  }

  // Calculate slope
  const slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);

  let trend: "improving" | "declining" | "stable";
  if (Math.abs(slope) < 0.5) {
    trend = "stable";
  } else if (slope > 0) {
    trend = "improving";
  } else {
    trend = "declining";
  }

  return { slope, trend };
}

/**
 * Validate quality score object
 */
export function validateQualityScore(
  score: unknown,
): score is IterationQualityScore {
  if (typeof score !== "object" || score === null) {
    return false;
  }

  const obj = score as Record<string, unknown>;
  return (
    typeof obj.iteration === "number" &&
    typeof obj.quality_score === "number" &&
    obj.quality_score >= 0 &&
    obj.quality_score <= 100
  );
}

/**
 * Parse quality score from event object
 */
export function parseQualityScoreFromEvent(
  event: Record<string, unknown>,
): IterationQualityScore | null {
  if (event.type !== "loop.quality_scored") {
    return null;
  }

  const iteration =
    typeof event.iteration === "string"
      ? parseInt(event.iteration, 10)
      : event.iteration;
  const quality_score =
    typeof event.quality_score === "string"
      ? parseInt(event.quality_score, 10)
      : event.quality_score;

  if (typeof iteration !== "number" || typeof quality_score !== "number") {
    return null;
  }

  const test_delta =
    typeof event.test_delta === "string"
      ? parseInt(event.test_delta, 10)
      : event.test_delta;
  const compile_success =
    typeof event.compile_success === "string"
      ? parseInt(event.compile_success, 10)
      : event.compile_success;
  const error_reduction =
    typeof event.error_reduction === "string"
      ? parseInt(event.error_reduction, 10)
      : event.error_reduction;
  const code_churn =
    typeof event.code_churn === "string"
      ? parseInt(event.code_churn, 10)
      : event.code_churn;

  return {
    iteration,
    quality_score,
    timestamp: (event.ts as string) || (event.timestamp as string),
    test_passed:
      event.test_passed === true || event.test_passed === "true"
        ? true
        : event.test_passed === false || event.test_passed === "false"
          ? false
          : undefined,
    components:
      typeof test_delta === "number" &&
      typeof compile_success === "number" &&
      typeof error_reduction === "number" &&
      typeof code_churn === "number"
        ? { test_delta, compile_success, error_reduction, code_churn }
        : undefined,
  };
}
