import { choice, type TypeSafeClient } from "@typesafe-ai/sdk";
import { truncateText } from "../classifier/jev.js";
import { DIFFICULTY_CRITERIA, DIFFICULTY_QUESTION, heuristicDifficulty, planRequest, type Budget, type Difficulty, type ModelTier } from "./tiers.js";
import type { RequestKind, RouteDecision } from "./types.js";

// POST /v1/assistant/route: should a chat request run on the device or as a cloud run, and on which model?
// Without `budget` (older apps): only multi-step tasks go to the cloud, on the large model.
// With `budget`: Jev also judges difficulty and tiers.ts picks the device or a cloud tier, cheapest that fits.

export const ROUTE_QUESTION = "這個要求需要哪一種處理？";
export const ROUTE_CRITERIA = {
  question: "查詢或問答：只需要搜尋、閱讀筆記後回答，或摘要一兩則筆記",
  edit: "對一則筆記做小幅新增或修改，例如記一筆、補一段、改一句",
  task: "需要多個步驟或處理多個檔案的工作：整理、分類、搬移、重新命名、批次建立或修改、彙整多則筆記、產生報表、分析資料或計算",
} as const;

const TASK_PATTERN = /整理|分類|搬|移動|移到|重新命名|改名|批次|全部|所有|每一|每個|彙整|匯總|統計|報表|表格|分析|計算|比較|清理|歸檔|合併|拆分|建立.*資料夾/;
const EDIT_PATTERN = /記下|記錄|新增|補上|加入|改成|修改|寫入|更新/;
export const HEURISTIC_CONFIDENCE = 0.6;
/** Jev's confidence a task needs before it goes to the cloud. */
export const CLOUD_MIN_CONFIDENCE = 0.5;

export function heuristicKind(text: string): RequestKind {
  if (TASK_PATTERN.test(text)) return "task";
  if (EDIT_PATTERN.test(text)) return "edit";
  return "question";
}

const isKind = (value: unknown): value is RequestKind => value === "question" || value === "edit" || value === "task";
const isDifficulty = (value: unknown): value is Difficulty => value === "simple" || value === "moderate" || value === "hard";
/** Below this confidence a Jev answer is taken one step cheaper (cost first when Jev is unsure). */
export const SURE_CONFIDENCE = 0.5;
const CHEAPER_DIFFICULTY: Record<Difficulty, Difficulty> = { hard: "moderate", moderate: "simple", simple: "simple" };

export interface RouteOptions {
  cloudAvailable: boolean;
  /** The user's budget; absent = the original device/cloud split. */
  budget?: Budget;
  /** Whether the phone can run Apple Intelligence (default true). */
  deviceAvailable?: boolean;
  /** The model a cloud tier uses right now (for the answer). */
  modelFor?: (tier: ModelTier) => string;
}

export class RequestRouter {
  constructor(
    /** Jev (TypeSafe System One); null = keyword heuristic only. */
    private readonly jev: Pick<TypeSafeClient, "systemOne"> | null,
    private readonly jevModel: string,
  ) {}

  async route(text: string, context: string | undefined, options: RouteOptions): Promise<RouteDecision> {
    if (options.budget) return this.routeWithBudget(text, context, { ...options, budget: options.budget });
    const { cloudAvailable } = options;
    let kind: RequestKind = heuristicKind(text);
    let confidence = HEURISTIC_CONFIDENCE;
    let provider: RouteDecision["provider"] = "heuristic";
    if (this.jev) {
      try {
        const response = await this.jev.systemOne({
          model: this.jevModel,
          state: { request: truncateText(text), ...(context ? { context: truncateText(context) } : {}) },
          questions: { kind: choice(ROUTE_QUESTION, ROUTE_CRITERIA) },
        });
        const answer = response.answers.kind;
        if (isKind(answer.choice) && Number.isFinite(answer.confidence)) {
          kind = answer.choice;
          confidence = answer.confidence;
          provider = "jev";
        }
      } catch (error) {
        console.warn(`[assistant] Jev routing failed, using the keyword heuristic: ${error instanceof Error ? error.name : "error"}`);
      }
    }
    const cloud = kind === "task" && cloudAvailable && (provider === "heuristic" || confidence >= CLOUD_MIN_CONFIDENCE);
    return { kind, route: cloud ? "cloud" : "device", confidence, provider, cloudAvailable };
  }

  /** Kind and difficulty in one Jev call, then the placement table. */
  private async routeWithBudget(text: string, context: string | undefined, options: RouteOptions & { budget: Budget }): Promise<RouteDecision> {
    let kind: RequestKind = heuristicKind(text);
    let difficulty: Difficulty = heuristicDifficulty(text, kind);
    let confidence = HEURISTIC_CONFIDENCE;
    let provider: RouteDecision["provider"] = "heuristic";
    if (this.jev) {
      try {
        const response = await this.jev.systemOne({
          model: this.jevModel,
          state: { request: truncateText(text), ...(context ? { context: truncateText(context) } : {}) },
          questions: { kind: choice(ROUTE_QUESTION, ROUTE_CRITERIA), difficulty: choice(DIFFICULTY_QUESTION, DIFFICULTY_CRITERIA) },
        });
        const kindAnswer = response.answers.kind;
        const difficultyAnswer = response.answers.difficulty;
        if (kindAnswer && isKind(kindAnswer.choice) && Number.isFinite(kindAnswer.confidence)) {
          provider = "jev";
          confidence = kindAnswer.confidence;
          // unsure that it is a multi-step task: treat it as a single edit (cheaper)
          kind = kindAnswer.choice === "task" && confidence < SURE_CONFIDENCE ? "edit" : kindAnswer.choice;
          difficulty = heuristicDifficulty(text, kind);
        }
        if (difficultyAnswer && isDifficulty(difficultyAnswer.choice) && Number.isFinite(difficultyAnswer.confidence)) {
          difficulty = difficultyAnswer.confidence < SURE_CONFIDENCE ? CHEAPER_DIFFICULTY[difficultyAnswer.choice] : difficultyAnswer.choice;
        }
      } catch (error) {
        console.warn(`[assistant] Jev routing failed, using the keyword heuristic: ${error instanceof Error ? error.name : "error"}`);
      }
    }
    const plan = planRequest(options.budget, kind, difficulty, { device: options.deviceAvailable ?? true, cloud: options.cloudAvailable });
    const tier = plan.placement === "device" ? null : plan.placement;
    return {
      kind,
      route: tier ? "cloud" : "device",
      confidence,
      provider,
      cloudAvailable: options.cloudAvailable,
      difficulty,
      budget: options.budget,
      tier: plan.placement,
      model: tier && options.modelFor ? options.modelFor(tier) : null,
      effort: plan.effort,
    };
  }
}
