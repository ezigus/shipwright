import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";
import * as api from "./api";

// Mock global fetch
const mockFetch = vi.fn();
global.fetch = mockFetch;

function jsonResponse(data: unknown, status = 200) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(data),
  });
}

function errorResponse(status: number, body?: unknown) {
  return Promise.resolve({
    ok: false,
    status,
    json: () => Promise.resolve(body || { error: `HTTP ${status}` }),
  });
}

describe("API Client", () => {
  beforeEach(() => {
    mockFetch.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("fetchMe", () => {
    it("calls GET /api/me", async () => {
      const userData = { username: "test", role: "admin" };
      mockFetch.mockReturnValueOnce(jsonResponse(userData));

      const result = await api.fetchMe();
      expect(result).toEqual(userData);
      expect(mockFetch).toHaveBeenCalledWith("/api/me", undefined);
    });
  });

  describe("fetchPipelineDetail", () => {
    it("calls GET /api/pipeline/:issue", async () => {
      const detail = { issue: 42, status: "building" };
      mockFetch.mockReturnValueOnce(jsonResponse(detail));

      const result = await api.fetchPipelineDetail(42);
      expect(result).toEqual(detail);
      expect(mockFetch).toHaveBeenCalledWith("/api/pipeline/42", undefined);
    });

    it("encodes special characters in issue", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      await api.fetchPipelineDetail("test/123");
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/test%2F123",
        undefined,
      );
    });
  });

  describe("fetchMetricsHistory", () => {
    it("defaults to 30 day period", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ history: [] }));
      await api.fetchMetricsHistory();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/history?period=30",
        undefined,
      );
    });

    it("respects custom period", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ history: [] }));
      await api.fetchMetricsHistory(7);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/metrics/history?period=7",
        undefined,
      );
    });
  });

  describe("fetchTimeline", () => {
    it("defaults to 24h range", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse([]));
      await api.fetchTimeline();
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/timeline?range=24h",
        undefined,
      );
    });
  });

  describe("fetchActivity", () => {
    it("builds query string from params", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ events: [], hasMore: false }),
      );
      await api.fetchActivity({ limit: 50, offset: 10, type: "error" });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain("/api/activity?");
      expect(url).toContain("limit=50");
      expect(url).toContain("offset=10");
      expect(url).toContain("type=error");
    });

    it("excludes type=all from query string", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ events: [], hasMore: false }),
      );
      await api.fetchActivity({ type: "all" });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).not.toContain("type=");
    });
  });

  describe("machine operations", () => {
    it("fetchMachines calls GET /api/machines", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse([]));
      await api.fetchMachines();
      expect(mockFetch).toHaveBeenCalledWith("/api/machines", undefined);
    });

    it("addMachine calls POST /api/machines", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ name: "m1" }));
      await api.addMachine({ name: "m1", host: "localhost" });

      expect(mockFetch).toHaveBeenCalledWith("/api/machines", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "m1", host: "localhost" }),
      });
    });

    it("updateMachine calls PATCH /api/machines/:name", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ name: "m1" }));
      await api.updateMachine("m1", { status: "active" });

      expect(mockFetch).toHaveBeenCalledWith("/api/machines/m1", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: "active" }),
      });
    });

    it("removeMachine calls DELETE /api/machines/:name", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.removeMachine("m1");

      expect(mockFetch).toHaveBeenCalledWith("/api/machines/m1", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
      });
    });
  });

  describe("fetchQueueDetailed", () => {
    it("transforms queue property to items", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ queue: [{ id: 1 }, { id: 2 }] }),
      );
      const result = await api.fetchQueueDetailed();
      expect(result).toEqual({ items: [{ id: 1 }, { id: 2 }] });
    });

    it("handles missing queue property gracefully", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({}));
      const result = await api.fetchQueueDetailed();
      expect(result).toEqual({ items: [] });
    });
  });

  describe("emergency brake", () => {
    it("calls POST /api/emergency-brake", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.emergencyBrake();

      expect(mockFetch).toHaveBeenCalledWith("/api/emergency-brake", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });
    });
  });

  describe("sendIntervention", () => {
    it("calls POST /api/intervention/:issue/:action with body", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.sendIntervention(42, "pause", { reason: "testing" });

      expect(mockFetch).toHaveBeenCalledWith("/api/intervention/42/pause", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reason: "testing" }),
      });
    });
  });

  describe("insights endpoints", () => {
    it("fetchPatterns returns empty array on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchPatterns();
      expect(result).toEqual({ patterns: [] });
    });

    it("fetchDecisions returns empty array on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchDecisions();
      expect(result).toEqual({ decisions: [] });
    });

    it("fetchHeatmap returns null on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchHeatmap();
      expect(result).toBeNull();
    });
  });

  describe("pipeline live changes", () => {
    it("fetchPipelineDiff calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({
          diff: "diff output",
          stats: { files_changed: 1, insertions: 10, deletions: 5 },
          worktree: "/path",
        }),
      );
      await api.fetchPipelineDiff(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/diff",
        undefined,
      );
    });

    it("fetchPipelineFiles calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({
          files: [{ path: "src/main.ts", status: "modified" }],
        }),
      );
      await api.fetchPipelineFiles(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/files",
        undefined,
      );
    });

    it("fetchPipelineReasoning calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ reasoning: [] }));
      await api.fetchPipelineReasoning(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/reasoning",
        undefined,
      );
    });

    it("fetchPipelineFailures calls correct endpoint", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ failures: [] }));
      await api.fetchPipelineFailures(142);
      expect(mockFetch).toHaveBeenCalledWith(
        "/api/pipeline/142/failures",
        undefined,
      );
    });
  });

  describe("approval gates", () => {
    it("approveGate sends POST with stage", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.approveGate(42, "build");

      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/approve", {
        method: "POST",
        body: JSON.stringify({ stage: "build" }),
      });
    });

    it("rejectGate sends POST with stage and reason", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.rejectGate(42, "build", "Failed QA");

      expect(mockFetch).toHaveBeenCalledWith("/api/approval-gates/42/reject", {
        method: "POST",
        body: JSON.stringify({ stage: "build", reason: "Failed QA" }),
      });
    });
  });

  describe("notifications", () => {
    it("addWebhook sends POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.addWebhook("https://slack.com/hook", "Slack", ["failure"]);

      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "POST",
        body: JSON.stringify({
          url: "https://slack.com/hook",
          label: "Slack",
          events: ["failure"],
        }),
      });
    });

    it("removeWebhook sends DELETE", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.removeWebhook("https://slack.com/hook");

      expect(mockFetch).toHaveBeenCalledWith("/api/notifications/webhook", {
        method: "DELETE",
        body: JSON.stringify({ url: "https://slack.com/hook" }),
      });
    });
  });

  describe("machine claim/release", () => {
    it("claimIssue sends POST with issue and machine", async () => {
      mockFetch.mockReturnValueOnce(
        jsonResponse({ approved: true, claimed_by: "m1" }),
      );
      const result = await api.claimIssue(42, "m1");
      expect(result.approved).toBe(true);
    });

    it("releaseIssue sends POST", async () => {
      mockFetch.mockReturnValueOnce(jsonResponse({ ok: true }));
      await api.releaseIssue(42, "m1");

      expect(mockFetch).toHaveBeenCalledWith("/api/claim/release", {
        method: "POST",
        body: JSON.stringify({ issue: 42, machine: "m1" }),
      });
    });
  });

  describe("error handling", () => {
    it("throws on non-ok response", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(404, { error: "Not found" }));

      await expect(api.fetchMe()).rejects.toThrow("Not found");
    });

    it("falls back to HTTP status on unparseable error", async () => {
      mockFetch.mockReturnValueOnce(
        Promise.resolve({
          ok: false,
          status: 500,
          json: () => Promise.reject(new Error("parse error")),
        }),
      );

      await expect(api.fetchMe()).rejects.toThrow("HTTP 500");
    });

    it("fetchPredictions returns empty object on error", async () => {
      mockFetch.mockReturnValueOnce(errorResponse(500));
      const result = await api.fetchPredictions(42);
      expect(result).toEqual({});
    });
  });
});
