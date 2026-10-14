// Public shapes of POST/GET /v1/assistant/runs (the iOS app is written against these field names).

export type RunStatus = "running" | "completed" | "failed" | "cancelled";

export type EditOp = "create" | "update" | "move" | "delete";

export interface AssistantEdit {
  id: string;
  op: EditOp;
  /** The file changed; for a move the destination, for a delete the original path. */
  path: string;
  /** Source path of a move. */
  from?: string;
  summary: string;
  undone: boolean;
}

interface EventBase {
  /** Increases by one per event within a run, starting at 1. */
  seq: number;
  /** ISO 8601. */
  at: string;
}

export type AssistantEventBody =
  | { type: "message"; text: string }
  | { type: "tool"; name: string; summary: string }
  | { type: "edit"; edit: AssistantEdit }
  | { type: "file"; path: string }
  | { type: "error"; message: string };

export type AssistantEvent = EventBase & AssistantEventBody;

export interface RunError {
  code: string;
  message: string;
}

export interface RunUsage {
  inputTokens: number;
  outputTokens: number;
}

export interface RunView {
  id: string;
  status: RunStatus;
  model: string;
  events: AssistantEvent[];
  answer: string | null;
  error: RunError | null;
  sources: string[];
  edits: AssistantEdit[];
  usage: RunUsage;
}

export type RequestKind = "question" | "edit" | "task";

export interface RouteDecision {
  kind: RequestKind;
  route: "device" | "cloud";
  confidence: number;
  provider: "jev" | "heuristic";
  cloudAvailable: boolean;
  /** The fields below are only present when the request named a budget. */
  difficulty?: "simple" | "moderate" | "hard";
  budget?: "low" | "medium" | "high";
  /** "device" or the cloud tier to start the run with. */
  tier?: "device" | "small" | "medium" | "large";
  /** The model that tier uses right now (null on the device). */
  model?: string | null;
  /** Thinking effort for the run (null on the device). */
  effort?: "low" | "medium" | "high" | null;
}

export interface UndoResult {
  undone: string[];
  failed: { id: string; reason: string }[];
}
