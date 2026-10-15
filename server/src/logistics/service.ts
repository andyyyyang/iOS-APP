import { z } from "zod";
import { AppError, notFound } from "../errors.js";
import { parse } from "../services/parse.js";
import type { VaultIndexService } from "../services/vault-index.js";
import type { VaultService } from "../services/vault.js";
import { COURIERS, STATUSES, STATUS_IDS, courierFor, courierName, guessCourier, trackingUrl, track17Url } from "./couriers.js";
import { Trackers, type TrackNode, type TrackResult, type TrackerOptions } from "./trackers.js";

// The logistics tracker (物流追蹤中心) as a server feature: the watch list stays in the vault file the desktop
// dataviewjs tool reads and writes (06 日誌/物流追蹤/watchlist.json, same fields), the server fetches progress
// (instead of the desktop Python script) and refreshes the active items in the background, so the list is current
// on the phone with or without the computer on.

export const DEFAULT_WATCHLIST_PATH = "06 日誌/物流追蹤/watchlist.json";
/** Pause between two couriers' requests in a batch refresh (the script queried one after another too). */
const REFRESH_GAP_MS = 400;

/** One tracked shipment, as stored in watchlist.json (unknown fields written by the desktop tool are kept). */
export interface WatchItem {
  tracking_number: string;
  courier_code: string;
  courier_name: string;
  note: string;
  status: string;
  is_archived: boolean;
  latest_event: string;
  latest_time: string;
  trackinfo: TrackNode[];
  updated_at: string;
  [key: string]: unknown;
}

/** A note whose frontmatter names a tracking number (the tool's 筆記單號關聯 tab). */
export interface LinkedNote {
  path: string;
  name: string;
  customer: string;
  caseNo: string;
  trackingNumber: string;
  courier: string;
  courierName: string;
  /** Already on the watch list. */
  tracked: boolean;
}

export interface LogisticsOptions extends TrackerOptions {
  /** Vault path of the watch list (LOGISTICS_PATH). */
  path?: string;
  /** Background refresh of the active items every this many minutes; 0 or undefined = off (LOGISTICS_REFRESH_MINUTES). */
  refreshMinutes?: number;
  /** For tests: a prepared tracker. */
  trackers?: Pick<Trackers, "track" | "sources">;
  logger?: Pick<Console, "info" | "warn">;
  /** Pause between requests in a batch (tests pass 0). */
  gapMs?: number;
}

const numberSchema = z
  .string()
  .transform((value) => value.trim().replace(/\s+/g, ""))
  .pipe(z.string().min(4, "too short").max(64).regex(/^[A-Za-z0-9-]+$/, "letters, digits and - only"));

const addSchema = z.object({
  courier: z.string().trim().min(1).max(40),
  number: numberSchema,
  note: z.string().max(500).optional(),
});

const updateSchema = z
  .object({
    note: z.string().max(500).optional(),
    status: z.enum(STATUS_IDS).optional(),
    archived: z.boolean().optional(),
  })
  .refine((body) => body.note !== undefined || body.status !== undefined || body.archived !== undefined, "nothing to change");

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown) => (typeof value === "string" ? value : typeof value === "number" ? String(value) : "");

/** A stored item with every field the app reads (tolerating items the desktop tool or older scripts wrote). */
export function normalizeItem(raw: Record<string, unknown>): WatchItem {
  const code = str(raw.courier_code) || "t-cat";
  return {
    ...raw,
    tracking_number: str(raw.tracking_number),
    courier_code: code,
    courier_name: str(raw.courier_name) || courierName(code),
    note: str(raw.note),
    status: str(raw.status) || "transit",
    is_archived: raw.is_archived === true,
    latest_event: str(raw.latest_event),
    latest_time: str(raw.latest_time),
    trackinfo: Array.isArray(raw.trackinfo)
      ? raw.trackinfo.filter(isObject).map((node) => ({
          checkpoint_date: str(node.checkpoint_date),
          location: str(node.location),
          tracking_detail: str(node.tracking_detail),
        }))
      : [],
    updated_at: str(raw.updated_at),
  };
}

/** watchlist.json's array; a missing or empty file is an empty list, anything but an array is refused. */
export function parseWatchlist(text: string): Record<string, unknown>[] {
  const body = text.replace(/^﻿/, "").trim();
  if (!body) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new AppError(422, "invalid_watchlist", "watchlist.json is not valid JSON");
  }
  if (!Array.isArray(parsed)) throw new AppError(422, "invalid_watchlist", "watchlist.json must be a JSON array");
  return parsed.filter(isObject);
}

/** A tracking result applied to an item: a failed or link-only answer never replaces progress already recorded. */
export function applyResult(item: WatchItem, result: TrackResult, at: string): WatchItem {
  const next: WatchItem = { ...item, updated_at: at };
  if (!result.live && item.latest_event) return next;
  next.status = result.status || item.status;
  next.latest_event = result.latest_event || item.latest_event;
  next.latest_time = result.latest_time || item.latest_time;
  if (result.trackinfo.length) next.trackinfo = result.trackinfo;
  return next;
}

export interface RefreshState {
  intervalMinutes: number;
  running: boolean;
  lastRunAt: string | null;
  lastRefreshed: number;
  lastError: string | null;
}

export class LogisticsService {
  readonly path: string;
  private readonly trackers: Pick<Trackers, "track" | "sources">;
  private readonly logger: Pick<Console, "info" | "warn">;
  private readonly gapMs: number;
  private readonly refreshMinutes: number;
  private refreshing: Promise<{ refreshed: number; items: WatchItem[] }> | null = null;
  private state: Omit<RefreshState, "intervalMinutes" | "running"> = { lastRunAt: null, lastRefreshed: 0, lastError: null };
  private timer: ReturnType<typeof setInterval> | null = null;
  private firstRun: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly deps: { vault: VaultService; vaultIndex: VaultIndexService; now?: () => number },
    options: LogisticsOptions = {},
  ) {
    this.path = options.path ?? DEFAULT_WATCHLIST_PATH;
    this.trackers = options.trackers ?? new Trackers(options);
    this.logger = options.logger ?? console;
    this.gapMs = options.gapMs ?? REFRESH_GAP_MS;
    this.refreshMinutes = Math.max(0, options.refreshMinutes ?? 0);
  }

  private nowIso(): string {
    return new Date((this.deps.now ?? Date.now)()).toISOString();
  }

  /** Couriers, statuses and what can be read live; for the app's settings tab and pickers. */
  meta() {
    const sources = this.trackers.sources;
    return {
      path: this.path,
      couriers: COURIERS.map((courier) => ({
        code: courier.code,
        name: courier.name,
        url: courier.url,
        live: courier.source === "tcat" || courier.source === "sf" || (courier.source === "dhl" && (sources.dhl || sources.track17)) || (courier.source === "17track" && sources.track17),
      })),
      statuses: STATUSES,
      dhl: sources.dhl,
      track17: sources.track17,
      refresh: this.refreshState(),
    };
  }

  refreshState(): RefreshState {
    return { intervalMinutes: this.refreshMinutes, running: this.refreshing !== null, ...this.state };
  }

  // MARK: the watch list file

  private async load(): Promise<{ raw: Record<string, unknown>[]; etag: string | null }> {
    try {
      const file = await this.deps.vault.read(this.path);
      return { raw: parseWatchlist(file.body.toString("utf8")), etag: file.etag };
    } catch (error) {
      if (error instanceof AppError && error.status === 404) return { raw: [], etag: null };
      throw error;
    }
  }

  /** Read, change, write with If-Match; a write that loses a race (the desktop tool saved) is redone on the new file. */
  private async mutate<T>(change: (items: WatchItem[]) => { items: WatchItem[]; result: T; changed?: boolean }): Promise<T> {
    for (let attempt = 0; ; attempt += 1) {
      const { raw, etag } = await this.load();
      const { items, result, changed = true } = change(raw.map(normalizeItem));
      if (!changed) return result;
      try {
        await this.deps.vault.write(this.path, Buffer.from(`${JSON.stringify(items, null, 2)}\n`, "utf8"), {
          ...(etag ? { ifMatch: etag } : { ifNoneMatch: "*" }),
          client: "logistics",
        });
        return result;
      } catch (error) {
        if (!(error instanceof AppError && error.status === 412) || attempt >= 3) throw error;
      }
    }
  }

  async list() {
    const { raw } = await this.load();
    return { items: raw.map(normalizeItem), ...this.meta() };
  }

  // MARK: changes from the app

  /** 新增追蹤: query the courier, then insert first (or update the same number, keeping its note when none is given). */
  async add(body: unknown): Promise<WatchItem> {
    const request = parse(addSchema, body ?? {});
    const code = request.courier.toLowerCase();
    const result = await this.trackers.track(code, request.number);
    const at = this.nowIso();
    return this.mutate((items) => {
      const index = items.findIndex((item) => item.tracking_number === request.number);
      const existing = index >= 0 ? items[index] : undefined;
      const base: WatchItem = {
        ...(existing ?? {}),
        tracking_number: request.number,
        courier_code: code,
        courier_name: courierName(code),
        note: request.note?.trim() || existing?.note || "",
        status: existing?.status ?? "transit",
        is_archived: false,
        latest_event: existing?.latest_event ?? "",
        latest_time: existing?.latest_time ?? "",
        trackinfo: existing?.trackinfo ?? [],
        updated_at: at,
      };
      const item = applyResult(base, result, at);
      if (!item.latest_event) item.latest_event = `【${item.courier_name}】單號追蹤中`;
      const next = [...items];
      if (existing) next[index] = item;
      else next.unshift(item);
      return { items: next, result: item };
    });
  }

  /** Note, status, 結案 (archived → delivered unless a status is given) and 恢復追蹤 (→ transit). */
  async update(number: string, body: unknown): Promise<WatchItem> {
    const request = parse(updateSchema, body ?? {});
    return this.mutate((items) => {
      const index = items.findIndex((item) => item.tracking_number === number);
      if (index < 0) throw notFound("Tracking number", number);
      const item = { ...items[index]! };
      if (request.note !== undefined) item.note = request.note.trim();
      if (request.archived !== undefined) {
        item.is_archived = request.archived;
        item.status = request.archived ? "delivered" : "transit";
      }
      if (request.status !== undefined) item.status = request.status;
      const next = [...items];
      next[index] = item;
      return { items: next, result: item };
    });
  }

  async remove(number: string): Promise<void> {
    await this.mutate((items) => {
      if (!items.some((item) => item.tracking_number === number)) throw notFound("Tracking number", number);
      return { items: items.filter((item) => item.tracking_number !== number), result: undefined };
    });
  }

  /** 結案已送達: every active item whose status is delivered. */
  async archiveDelivered(): Promise<{ archived: number }> {
    return this.mutate((items) => {
      let archived = 0;
      const next = items.map((item) => {
        if (item.is_archived || item.status !== "delivered") return item;
        archived += 1;
        return { ...item, is_archived: true };
      });
      return { items: next, result: { archived }, changed: archived > 0 };
    });
  }

  /** 清空結案清單. */
  async clearArchived(): Promise<{ removed: number }> {
    return this.mutate((items) => {
      const next = items.filter((item) => !item.is_archived);
      return { items: next, result: { removed: items.length - next.length }, changed: next.length !== items.length };
    });
  }

  // MARK: tracking

  async refreshOne(number: string): Promise<WatchItem> {
    const { raw } = await this.load();
    const current = raw.map(normalizeItem).find((item) => item.tracking_number === number);
    if (!current) throw notFound("Tracking number", number);
    const result = await this.trackers.track(current.courier_code, number);
    const at = this.nowIso();
    return this.mutate((items) => {
      const index = items.findIndex((item) => item.tracking_number === number);
      if (index < 0) throw notFound("Tracking number", number);
      const item = applyResult(items[index]!, result, at);
      const next = [...items];
      next[index] = item;
      return { items: next, result: item };
    });
  }

  /** 批次背景刷新: every active item, one request after another; a refresh already running is joined. */
  refreshAll(): Promise<{ refreshed: number; items: WatchItem[] }> {
    if (this.refreshing) return this.refreshing;
    const run = this.runRefresh().finally(() => {
      this.refreshing = null;
    });
    this.refreshing = run;
    return run;
  }

  private async runRefresh(): Promise<{ refreshed: number; items: WatchItem[] }> {
    try {
      const { raw } = await this.load();
      const active = raw.map(normalizeItem).filter((item) => !item.is_archived && item.tracking_number);
      const results = new Map<string, TrackResult>();
      for (const [index, item] of active.entries()) {
        if (index > 0 && this.gapMs > 0) await new Promise((resolve) => setTimeout(resolve, this.gapMs));
        results.set(item.tracking_number, await this.trackers.track(item.courier_code, item.tracking_number));
      }
      const at = this.nowIso();
      const items = results.size
        ? await this.mutate((current) => {
            const next = current.map((item) => {
              const result = results.get(item.tracking_number);
              return result && !item.is_archived ? applyResult(item, result, at) : item;
            });
            return { items: next, result: next };
          })
        : raw.map(normalizeItem);
      this.state = { lastRunAt: at, lastRefreshed: results.size, lastError: null };
      return { refreshed: results.size, items };
    } catch (error) {
      this.state = { ...this.state, lastRunAt: this.nowIso(), lastError: error instanceof Error ? error.message : String(error) };
      throw error;
    }
  }

  /** Background refresh: a first run a minute after startup, then every `refreshMinutes` (timers don't keep the process alive). */
  start(): void {
    if (!this.refreshMinutes || this.timer || !this.deps.vault.status().configured) return;
    const run = () => {
      this.refreshAll()
        .then(({ refreshed }) => {
          if (refreshed) this.logger.info(`[logistics] refreshed ${refreshed} tracking number(s)`);
        })
        .catch((error: unknown) => this.logger.warn(`[logistics] background refresh failed: ${error instanceof Error ? error.message : String(error)}`));
    };
    this.firstRun = setTimeout(run, 60_000);
    this.timer = setInterval(run, this.refreshMinutes * 60_000);
    this.firstRun.unref?.();
    this.timer.unref?.();
  }

  stop(): void {
    if (this.firstRun) clearTimeout(this.firstRun);
    if (this.timer) clearInterval(this.timer);
    this.firstRun = null;
    this.timer = null;
  }

  // MARK: notes

  /** Notes whose frontmatter names a tracking number (tracking_no, tracking_number, waybill, tcat_no, sf_no, dhl_no, fedex_no). */
  async linked(): Promise<{ notes: LinkedNote[] }> {
    const [snapshot, { raw }] = await Promise.all([this.deps.vaultIndex.snapshot(), this.load()]);
    const tracked = new Set(raw.map((item) => str(item.tracking_number)));
    const notes = snapshot.body.notes.flatMap((note): LinkedNote[] => {
      const props = note.properties;
      const first = (value: unknown) => (Array.isArray(value) ? str(value[0]) : str(value)).trim();
      const keyed: [string, string | null][] = [
        ["tracking_no", null],
        ["tracking_number", null],
        ["waybill", null],
        ["tcat_no", "t-cat"],
        ["sf_no", "sf-express"],
        ["dhl_no", "dhl"],
        ["fedex_no", "fedex"],
      ];
      const hit = keyed.map(([key, courier]) => ({ value: first(props[key]), courier })).find((entry) => entry.value);
      if (!hit) return [];
      const declared = first(props.courier).toLowerCase();
      const courier = (declared && courierFor(declared)?.code) || declared || hit.courier || guessCourier(hit.value) || "t-cat";
      const name = note.path.slice(note.path.lastIndexOf("/") + 1).replace(/\.md$/i, "");
      return [
        {
          path: note.path,
          name,
          customer: first(props.customer),
          caseNo: first(props.case_no) || name,
          trackingNumber: hit.value,
          courier,
          courierName: courierName(courier),
          tracked: tracked.has(hit.value),
        },
      ];
    });
    return { notes };
  }
}

export { trackingUrl, track17Url };
