import { beforeEach, describe, expect, it, vi } from "vitest";

// Marks and notes are saved 300 ms after the last edit. Opening another review in that window must still
// save the edits to the review they were made in, and must not save them into the new one.
const saved: { head: string; headSha: string; state: unknown }[] = [];
const stored = new Map<string, unknown>();
vi.mock("./backend", () => ({
  loadReviewState: vi.fn(async (_root: string, _head: string, headSha: string) => stored.get(headSha) ?? null),
  saveReviewState: vi.fn(async (_root: string, head: string, headSha: string, state: unknown) => {
    saved.push({ head, headSha, state: structuredClone(state) });
  }),
}));

const { initReview, setReviewed, flushReview, resetReview } = await import("./review");
const report = (headSha: string) => ({ repo: { root: "/repo", head: `branch-${headSha}`, headSha } }) as never;

describe("review state", () => {
  beforeEach(async () => {
    await flushReview();
    saved.length = 0;
    stored.clear();
    resetReview();
  });

  it("saves pending edits to their own review before another review opens", async () => {
    vi.useFakeTimers();
    try {
      await initReview(report("aaa"));
      setReviewed("item-a", true);
      stored.set("bbb", { reviewed: { "item-b": true }, notes: {} });
      await initReview(report("bbb"));
      await vi.runAllTimersAsync();
    } finally {
      vi.useRealTimers();
    }
    expect(saved).toEqual([{ head: "branch-aaa", headSha: "aaa", state: { reviewed: { "item-a": true }, notes: {} } }]);
  });

  it("saves an edit once, after the delay", async () => {
    vi.useFakeTimers();
    try {
      await initReview(report("ccc"));
      setReviewed("one", true);
      setReviewed("two", true);
      expect(saved).toEqual([]);
      await vi.advanceTimersByTimeAsync(300);
    } finally {
      vi.useRealTimers();
    }
    expect(saved).toEqual([{ head: "branch-ccc", headSha: "ccc", state: { reviewed: { one: true, two: true }, notes: {} } }]);
  });
});
