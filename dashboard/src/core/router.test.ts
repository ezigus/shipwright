import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";

// We need to mock the DOM and store before importing the router
describe("Router", () => {
  let store: any;
  let router: typeof import("./router");

  beforeEach(async () => {
    // Reset DOM
    document.body.innerHTML = `
      <div class="tab-btn" data-tab="overview">Overview</div>
      <div class="tab-btn" data-tab="pipelines">Pipelines</div>
      <div class="tab-btn" data-tab="metrics">Metrics</div>
      <div class="tab-btn" data-tab="team">Team</div>
      <div class="tab-panel" id="panel-overview"></div>
      <div class="tab-panel" id="panel-pipelines"></div>
      <div class="tab-panel" id="panel-metrics"></div>
      <div class="tab-panel" id="panel-team"></div>
    `;

    // Reset hash
    location.hash = "";

    // Fresh imports
    vi.resetModules();
    store = (await import("./state")).store;
    router = await import("./router");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("registerView", () => {
    it("registers a view for a tab", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);

      const views = router.getRegisteredViews();
      expect(views.get("overview")).toBe(mockView);
    });
  });

  describe("switchTab", () => {
    it("updates the active tab in the store", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");
      expect(store.get("activeTab")).toBe("pipelines");
    });

    it("updates the location hash", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");
      expect(location.hash).toBe("#pipelines");
    });

    it("adds active class to the correct tab button", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");

      const btns = document.querySelectorAll(".tab-btn");
      const pipelinesBtn = Array.from(btns).find(
        (b) => b.getAttribute("data-tab") === "pipelines",
      );
      const overviewBtn = Array.from(btns).find(
        (b) => b.getAttribute("data-tab") === "overview",
      );

      expect(pipelinesBtn?.classList.contains("active")).toBe(true);
      expect(overviewBtn?.classList.contains("active")).toBe(false);
    });

    it("adds active class to the correct panel", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");

      const pipelinesPanel = document.getElementById("panel-pipelines");
      const overviewPanel = document.getElementById("panel-overview");

      expect(pipelinesPanel?.classList.contains("active")).toBe(true);
      expect(overviewPanel?.classList.contains("active")).toBe(false);
    });

    it("does nothing when switching to the current tab", () => {
      store.set("activeTab", "overview");
      const prevHash = location.hash;
      router.switchTab("overview");
      // Should not change anything
      expect(store.get("activeTab")).toBe("overview");
    });

    it("initializes the view on first switch", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", mockView);

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      expect(mockView.init).toHaveBeenCalledTimes(1);
    });

    it("destroys the previous view on tab switch", () => {
      const overviewView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      const metricsView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };

      router.registerView("overview", overviewView);
      router.registerView("metrics", metricsView);

      // First, switch to overview so it gets initialized
      store.set("activeTab", "pipelines");
      router.switchTab("overview");
      expect(overviewView.init).toHaveBeenCalledTimes(1);

      // Now switch to metrics
      router.switchTab("metrics");
      expect(overviewView.destroy).toHaveBeenCalledTimes(1);
      expect(metricsView.init).toHaveBeenCalledTimes(1);
    });

    it("renders with fleet state if available", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", mockView);

      const fakeState = { pipelines: [], machines: [] };
      store.set("fleetState", fakeState);
      store.set("activeTab", "overview");

      router.switchTab("metrics");
      expect(mockView.render).toHaveBeenCalledWith(fakeState);
    });
  });

  describe("error boundaries", () => {
    it("catches init errors and shows error boundary", () => {
      const errorView = {
        init: vi.fn(() => {
          throw new Error("Init failed!");
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      // Suppress console.error for this test
      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain("Init failed!");

      consoleSpy.mockRestore();
    });

    it("catches render errors and shows error boundary", () => {
      const errorView = {
        init: vi.fn(),
        render: vi.fn(() => {
          throw new Error("Render exploded!");
        }),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("fleetState", { pipelines: [] });
      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain("Render exploded!");

      consoleSpy.mockRestore();
    });

    it("does not stack multiple error boundaries", () => {
      const errorView = {
        init: vi.fn(() => {
          throw new Error("Fail");
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      // Try to trigger again (should not add second boundary)
      store.set("activeTab", "pipelines");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const boundaries = panel?.querySelectorAll(".tab-error-boundary");
      expect(boundaries?.length).toBeLessThanOrEqual(1);

      consoleSpy.mockRestore();
    });
  });

  describe("renderActiveView", () => {
    it("renders the current active view with fleet state", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);

      const fakeState = { pipelines: [] };
      store.set("fleetState", fakeState);
      store.set("activeTab", "overview");

      router.renderActiveView();

      expect(mockView.render).toHaveBeenCalledWith(fakeState);
    });

    it("does nothing when no fleet state is available", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);
      store.set("activeTab", "overview");

      router.renderActiveView();
      expect(mockView.render).not.toHaveBeenCalled();
    });
  });
});
