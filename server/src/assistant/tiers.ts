import type { RequestKind } from "./types.js";

// Budget × difficulty → which AI answers. Every budget picks automatically and always by how hard the request is:
// easy things stay on the device (free) at every budget; a higher budget only means a hard request gets a better
// (more expensive) model sooner. Cloud tiers map to model families that follow new releases (catalog.ts).

/** The user's budget setting. */
export type Budget = "low" | "medium" | "high";
/** How hard Jev (or the keyword heuristic) judges the request. */
export type Difficulty = "simple" | "moderate" | "hard";
/** Cloud model tiers, cheapest first: small = newest Haiku, medium = newest Sonnet, large = newest Opus (ASSISTANT_MODEL*). */
export type ModelTier = "small" | "medium" | "large";
/** How much the model thinks (Messages API output_config.effort): more effort, more tokens. */
export type Effort = "low" | "medium" | "high";
/** Where a request runs: "device" = Apple Intelligence on the phone (free), or a cloud tier. */
export type Placement = "device" | ModelTier;

export const BUDGETS: readonly Budget[] = ["low", "medium", "high"];
export const MODEL_TIERS: readonly ModelTier[] = ["small", "medium", "large"];
export const EFFORTS: readonly Effort[] = ["low", "medium", "high"];

export const DIFFICULTY_QUESTION = "完成這個要求有多難？";
export const DIFFICULTY_CRITERIA = {
  simple: "簡單：一兩個步驟就好，答案在一兩則筆記裡，或只是記一筆、改一句",
  moderate: "中等：要讀好幾則筆記再整理成摘要或比較，或修改一則較長的筆記，或幾個檔案的小整理",
  hard: "困難：要跨很多筆記推理、分析或計算，或大量檔案的整理、搬移、批次修改，或需要寫程式處理資料",
} as const;

/**
 * The placement table. Rows: budget; columns: kind × difficulty.
 * - low: stay on the device unless the device can't do it well (hard requests, multi-step tasks), then the cheapest tier
 * - medium: device for simple questions and edits; cloud tiers rise with difficulty
 * - high: still the device for simple questions; better models for anything harder
 */
const TABLE: Record<Budget, Record<RequestKind, Record<Difficulty, Placement>>> = {
  low: {
    question: { simple: "device", moderate: "device", hard: "small" },
    edit: { simple: "device", moderate: "device", hard: "small" },
    task: { simple: "device", moderate: "small", hard: "medium" },
  },
  medium: {
    question: { simple: "device", moderate: "small", hard: "medium" },
    edit: { simple: "device", moderate: "small", hard: "medium" },
    task: { simple: "small", moderate: "medium", hard: "large" },
  },
  high: {
    question: { simple: "device", moderate: "medium", hard: "large" },
    edit: { simple: "device", moderate: "medium", hard: "large" },
    task: { simple: "medium", moderate: "large", hard: "large" },
  },
};

/** Thinking effort grows with difficulty; the low budget never goes above medium. */
const EFFORT: Record<Difficulty, Effort> = { simple: "low", moderate: "medium", hard: "high" };

export interface Plan {
  placement: Placement;
  /** null on the device. */
  effort: Effort | null;
}

/**
 * Where this request runs. Without Apple Intelligence on the device, device work goes to the cheapest cloud tier;
 * without cloud AI, everything stays on the device.
 */
export function planRequest(
  budget: Budget,
  kind: RequestKind,
  difficulty: Difficulty,
  available: { device: boolean; cloud: boolean },
): Plan {
  let placement = TABLE[budget][kind][difficulty];
  if (placement === "device" && !available.device && available.cloud) placement = "small";
  if (placement !== "device" && !available.cloud) placement = "device";
  if (placement === "device") return { placement, effort: null };
  const effort = budget === "low" && EFFORT[difficulty] === "high" ? "medium" : EFFORT[difficulty];
  return { placement, effort };
}

const MANY = /全部|所有|每一|每個|大量|批次|跨|整個/;
const ANALYSIS = /分析|計算|統計|報表|比較|程式|圖表|預測/;
const GATHER = /彙整|匯總|摘要|總結|整理|歸納|列出/;

/** Keyword fallback when Jev is not configured or fails. */
export function heuristicDifficulty(text: string, kind: RequestKind): Difficulty {
  if (MANY.test(text) || (kind === "task" && ANALYSIS.test(text))) return "hard";
  if (kind === "task" || ANALYSIS.test(text) || GATHER.test(text) || text.length > 300) return "moderate";
  return "simple";
}
