import { describe, it, expect } from "vitest";
import {
  getQualityScoreColor,
  getQualityScoreLabel,
  computeTrend,
  formatQualityScore,
  formatComponentBreakdown,
  shouldAdaptPrompt,
  shouldEscalateModel,
  computeAverageQuality,
  computeQualityTrendLine,
  validateQualityScore,
  parseQualityScoreFromEvent,
} from "./quality-score.js";
import { IterationQualityScore } from "../types/api.js";

describe("Quality Score Helpers", () => {
  describe("getQualityScoreColor", () => {
    it("returns red for critical scores (< 15)", () => {
      const color = getQualityScoreColor(10);
      expect(color.border).toContain("220");
      expect(color.bg).toContain("127");
    });

    it("returns orange for poor scores (15-30)", () => {
      const color = getQualityScoreColor(20);
      expect(color.border).toContain("234");
    });

    it("returns yellow for fair scores (30-70)", () => {
      const color = getQualityScoreColor(50);
      expect(color.border).toContain("202");
    });

    it("returns green for good scores (70+)", () => {
      const color = getQualityScoreColor(80);
      expect(color.border).toContain("34");
    });
  });

  describe("getQualityScoreLabel", () => {
    it("returns 'Critical' for scores < 15", () => {
      expect(getQualityScoreLabel(10)).toBe("Critical");
    });

    it("returns 'Poor' for scores 15-30", () => {
      expect(getQualityScoreLabel(20)).toBe("Poor");
    });

    it("returns 'Fair' for scores 30-50", () => {
      expect(getQualityScoreLabel(40)).toBe("Fair");
    });

    it("returns 'Good' for scores 50-70", () => {
      expect(getQualityScoreLabel(60)).toBe("Good");
    });

    it("returns 'Very Good' for scores 70-85", () => {
      expect(getQualityScoreLabel(75)).toBe("Very Good");
    });

    it("returns 'Excellent' for scores 85+", () => {
      expect(getQualityScoreLabel(90)).toBe("Excellent");
    });
  });

  describe("formatQualityScore", () => {
    it("formats score to one decimal place", () => {
      expect(formatQualityScore(66.666)).toBe("66.7");
    });

    it("handles whole numbers", () => {
      expect(formatQualityScore(50)).toBe("50.0");
    });
  });

  describe("computeTrend", () => {
    it("returns 'stable' when no previous score", () => {
      expect(computeTrend(undefined, 50)).toBe("stable");
    });

    it("returns 'stable' for small differences (< 3)", () => {
      expect(computeTrend(50, 51)).toBe("stable");
    });

    it("returns 'improving' when score increases", () => {
      expect(computeTrend(50, 60)).toBe("improving");
    });

    it("returns 'declining' when score decreases", () => {
      expect(computeTrend(60, 50)).toBe("declining");
    });
  });

  describe("formatComponentBreakdown", () => {
    it("formats component scores", () => {
      const result = formatComponentBreakdown({
        test_delta: 60,
        compile_success: 100,
        error_reduction: 75,
        code_churn: 50,
      });
      expect(result).toContain("test_delta: 60");
      expect(result).toContain("compile: 100");
    });

    it("returns placeholder when no components", () => {
      expect(formatComponentBreakdown(undefined)).toBe("No component data");
    });
  });

  describe("shouldAdaptPrompt", () => {
    it("returns true for scores < 30", () => {
      expect(shouldAdaptPrompt(25)).toBe(true);
    });

    it("returns false for scores >= 30", () => {
      expect(shouldAdaptPrompt(30)).toBe(false);
      expect(shouldAdaptPrompt(50)).toBe(false);
    });
  });

  describe("shouldEscalateModel", () => {
    it("returns true for scores < 15", () => {
      expect(shouldEscalateModel(10)).toBe(true);
    });

    it("returns false for scores >= 15", () => {
      expect(shouldEscalateModel(15)).toBe(false);
      expect(shouldEscalateModel(50)).toBe(false);
    });
  });

  describe("computeAverageQuality", () => {
    it("computes average of multiple scores", () => {
      const scores: IterationQualityScore[] = [
        { iteration: 1, quality_score: 50 },
        { iteration: 2, quality_score: 60 },
        { iteration: 3, quality_score: 70 },
      ];
      expect(computeAverageQuality(scores)).toBe(60);
    });

    it("returns 0 for empty array", () => {
      expect(computeAverageQuality([])).toBe(0);
    });
  });

  describe("computeQualityTrendLine", () => {
    it("returns stable trend for single score", () => {
      const scores: IterationQualityScore[] = [
        { iteration: 1, quality_score: 50 },
      ];
      const result = computeQualityTrendLine(scores);
      expect(result.trend).toBe("stable");
    });

    it("detects improving trend", () => {
      const scores: IterationQualityScore[] = [
        { iteration: 1, quality_score: 40 },
        { iteration: 2, quality_score: 50 },
        { iteration: 3, quality_score: 60 },
      ];
      const result = computeQualityTrendLine(scores);
      expect(result.slope).toBeGreaterThan(0);
      expect(result.trend).toBe("improving");
    });

    it("detects declining trend", () => {
      const scores: IterationQualityScore[] = [
        { iteration: 1, quality_score: 60 },
        { iteration: 2, quality_score: 50 },
        { iteration: 3, quality_score: 40 },
      ];
      const result = computeQualityTrendLine(scores);
      expect(result.slope).toBeLessThan(0);
      expect(result.trend).toBe("declining");
    });
  });

  describe("validateQualityScore", () => {
    it("validates valid score", () => {
      const score: IterationQualityScore = {
        iteration: 1,
        quality_score: 50,
      };
      expect(validateQualityScore(score)).toBe(true);
    });

    it("rejects invalid score (missing iteration)", () => {
      expect(validateQualityScore({ quality_score: 50 })).toBe(false);
    });

    it("rejects out-of-range score", () => {
      expect(validateQualityScore({ iteration: 1, quality_score: 150 })).toBe(
        false,
      );
    });

    it("rejects non-object", () => {
      expect(validateQualityScore("not an object")).toBe(false);
    });
  });

  describe("parseQualityScoreFromEvent", () => {
    it("parses valid quality_scored event", () => {
      const event = {
        type: "loop.quality_scored",
        iteration: "1",
        quality_score: "50",
        test_delta: "60",
        compile_success: "100",
        error_reduction: "75",
        code_churn: "50",
        ts: "2026-03-08T10:00:00Z",
      };
      const result = parseQualityScoreFromEvent(event);
      expect(result).not.toBeNull();
      expect(result?.iteration).toBe(1);
      expect(result?.quality_score).toBe(50);
      expect(result?.components?.test_delta).toBe(60);
    });

    it("parses event with numeric values", () => {
      const event = {
        type: "loop.quality_scored",
        iteration: 1,
        quality_score: 50,
        test_delta: 60,
        ts: "2026-03-08T10:00:00Z",
      };
      const result = parseQualityScoreFromEvent(event);
      expect(result?.iteration).toBe(1);
      expect(result?.quality_score).toBe(50);
    });

    it("returns null for wrong event type", () => {
      const event = {
        type: "loop.iteration_complete",
        iteration: "1",
        quality_score: "50",
      };
      expect(parseQualityScoreFromEvent(event)).toBeNull();
    });

    it("returns null for invalid quality_score", () => {
      const event = {
        type: "loop.quality_scored",
        iteration: "1",
        quality_score: "not a number",
      };
      expect(parseQualityScoreFromEvent(event)).toBeNull();
    });
  });
});
