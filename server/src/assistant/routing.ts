import { choice, type TypeSafeClient } from "@typesafe-ai/sdk";
import { truncateText } from "../classifier/jev.js";
import type { RequestKind, RouteDecision } from "./types.js";

// POST /v1/assistant/route: should a chat request run on the device or as a cloud run?

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

export class RequestRouter {
  constructor(
    /** Jev (TypeSafe System One); null = keyword heuristic only. */
    private readonly jev: Pick<TypeSafeClient, "systemOne"> | null,
    private readonly jevModel: string,
  ) {}

  async route(text: string, context: string | undefined, cloudAvailable: boolean): Promise<RouteDecision> {
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
}
