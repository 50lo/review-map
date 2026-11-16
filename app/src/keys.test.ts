import { describe, expect, it } from "vitest";
import { regionStep, type KeyPress } from "./keys";

const press = (key: string, mods: Partial<KeyPress> = {}): KeyPress => ({ key, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods });

describe("regionStep", () => {
  it("steps with Cmd and the arrow keys", () => {
    expect(regionStep(press("ArrowRight", { metaKey: true }))).toBe(1);
    expect(regionStep(press("ArrowLeft", { metaKey: true }))).toBe(-1);
  });

  it("steps with ] and [", () => {
    expect(regionStep(press("]"))).toBe(1);
    expect(regionStep(press("["))).toBe(-1);
  });

  it("no longer steps with j and k", () => {
    expect(regionStep(press("j"))).toBe(0);
    expect(regionStep(press("k"))).toBe(0);
  });

  it("leaves arrows without Cmd, or with other modifiers, alone", () => {
    expect(regionStep(press("ArrowRight"))).toBe(0);
    expect(regionStep(press("ArrowLeft", { metaKey: true, shiftKey: true }))).toBe(0);
    expect(regionStep(press("ArrowRight", { metaKey: true, altKey: true }))).toBe(0);
    expect(regionStep(press("ArrowRight", { ctrlKey: true }))).toBe(0);
    expect(regionStep(press("ArrowUp", { metaKey: true }))).toBe(0);
    expect(regionStep(press("]", { metaKey: true }))).toBe(0);
  });
});
