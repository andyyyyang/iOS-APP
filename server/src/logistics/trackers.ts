import { courierFor, courierName } from "./couriers.js";

// Reading a shipment's progress, server-side (the desktop tool ran scripts/logistics_tracker.py with Python):
// - 黑貓 (T-Cat): the public TraceDetail page, parsed like the script's BeautifulSoup table walk.
// - 順豐 (SF): the website's route API the script used (it no longer answers for most numbers; then link only).
// - DHL: DHL's official Shipment Tracking - Unified API when DHL_API_KEY is set (free key, 250 calls a day).
// - Everything else (FedEx, UPS, 新竹, 嘉里大榮, 郵局, and DHL without a key): 17TRACK's official API when
//   TRACK17_API_KEY is set (the script drove 17TRACK's website with a headless browser instead).
// Without a source the item keeps a "check on the courier's site" note and the app links to that page.

export interface TrackNode {
  /** e.g. "2026/10/05 15:40" (as the courier writes it, local time). */
  checkpoint_date: string;
  location: string;
  tracking_detail: string;
}

export interface TrackResult {
  status: string;
  latest_event: string;
  latest_time: string;
  /** Newest first. */
  trackinfo: TrackNode[];
  /** True when the courier (or 17TRACK) answered; false for the "check on the site" fallback or a failed request. */
  live: boolean;
}

export interface TrackerOptions {
  fetch?: typeof fetch;
  dhlApiKey?: string;
  track17ApiKey?: string;
  now?: () => Date;
  /** For "now" timestamps (default Asia/Taipei, where the couriers and the user are). */
  timeZone?: string;
}

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
  "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
};
const TIMEOUT_MS = 15_000;

/** "YYYY-MM-DD HH:mm" in `timeZone` (the script's datetime.now().strftime("%Y-%m-%d %H:%M")). */
export function formatNow(now: Date, timeZone = "Asia/Taipei"): string {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
      .formatToParts(now)
      .map((part) => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`;
}

/** "2026/10/05 15:40" style: date and time joined by one space (the script's format_checkpoint_time). */
export function formatCheckpointTime(value: string): string {
  const text = value.trim().replace(/\s+/g, " ");
  const match = /^(\d{4}[/-]\d{1,2}[/-]\d{1,2})\s*(\d{1,2}:\d{2}(?::\d{2})?)$/.exec(text);
  return match ? `${match[1]} ${match[2]}` : text;
}

/** An ISO time as the local time it names: "2026-10-05T15:40:00+08:00" → "2026-10-05 15:40". */
export function formatIsoLocal(value: string | undefined | null): string {
  if (!value) return "";
  const match = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})/.exec(value);
  return match ? `${match[1]} ${match[2]}` : value;
}

const decodeEntities = (text: string) =>
  text
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)));

/** A cell's text: <br> as a space, tags removed, whitespace collapsed. */
function cellText(html: string): string {
  return decodeEntities(html.replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
}

/** Rows of the first table with class "tablelist" (else the first table), each as its cells' text. */
export function tableRows(html: string): string[][] | null {
  const tables = [...html.matchAll(/<table\b([^>]*)>([\s\S]*?)<\/table>/gi)];
  const table = tables.find((match) => /class\s*=\s*["'][^"']*\btablelist\b/i.test(match[1] ?? "")) ?? tables[0];
  if (!table) return null;
  return [...(table[2] ?? "").matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)].map((row) =>
    [...(row[1] ?? "").matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map((cell) => cellText(cell[1] ?? "")),
  );
}

/** The script's T-Cat status words. */
export function tcatStatus(event: string): string {
  if (/送達|簽收/.test(event)) return "delivered";
  if (/攬收|集運|取件/.test(event)) return "pickup";
  if (/異常|未順利|退件/.test(event)) return "exception";
  return "transit";
}

export function parseTcat(html: string, number: string, nowText: string): TrackResult {
  const rows = tableRows(html);
  const trackinfo: TrackNode[] = [];
  for (const cells of (rows ?? []).slice(1)) {
    let status: string;
    let time: string;
    let location: string;
    // the first row carries the number in a rowspan cell; the rest start with the status
    if (cells.length >= 4 && cells[0] === number) [, status = "", time = "", location = ""] = cells;
    else if (cells.length >= 3) [status = "", time = "", location = ""] = cells;
    else continue;
    trackinfo.push({
      checkpoint_date: formatCheckpointTime(time),
      location,
      tracking_detail: location ? `${status} [${location}]` : status,
    });
  }
  if (!trackinfo.length) {
    return {
      status: "notfound",
      latest_event: rows ? "黑貓系統尚無此單號節點記錄" : "黑貓系統查無此單號狀態（資料處理中或尚未收件）",
      latest_time: nowText,
      trackinfo: [],
      live: true,
    };
  }
  const latest = trackinfo[0]!;
  return { status: tcatStatus(latest.tracking_detail), latest_event: latest.tracking_detail, latest_time: latest.checkpoint_date, trackinfo, live: true };
}

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);
const text = (value: unknown) => (typeof value === "string" ? value : typeof value === "number" ? String(value) : "");
const withLocation = (detail: string, location: string) => (location ? `${detail} [${location}]` : detail);

/** SF's route API: { success, data: { routes: [{ scanDateTime, stayCity, remark }] } }; null when it has no routes. */
export function parseSf(json: unknown): TrackResult | null {
  if (!isObject(json) || json.success !== true || !isObject(json.data)) return null;
  const routes = Array.isArray(json.data.routes) ? json.data.routes : [];
  const trackinfo = routes.filter(isObject).map((route) => ({
    checkpoint_date: text(route.scanDateTime),
    location: text(route.stayCity),
    tracking_detail: text(route.remark),
  }));
  if (!trackinfo.length) return null;
  const latest = trackinfo[0]!;
  const status = /簽收|送達/.test(latest.tracking_detail) ? "delivered" : /收取|攬收/.test(latest.tracking_detail) ? "pickup" : "transit";
  return { status, latest_event: latest.tracking_detail, latest_time: latest.checkpoint_date, trackinfo, live: true };
}

const DHL_STATUS: Record<string, string> = { delivered: "delivered", transit: "transit", "pre-transit": "pickup", failure: "exception" };

/** DHL Shipment Tracking - Unified: { shipments: [{ status, events: [{ timestamp, location, description, statusCode }] }] }. */
export function parseDhl(json: unknown): TrackResult | null {
  if (!isObject(json) || !Array.isArray(json.shipments) || !isObject(json.shipments[0])) return null;
  const shipment = json.shipments[0];
  const locality = (value: unknown) => (isObject(value) && isObject(value.address) ? text(value.address.addressLocality) : "");
  const events = (Array.isArray(shipment.events) ? shipment.events : []).filter(isObject);
  const trackinfo = events.map((event) => {
    const location = locality(event.location);
    return {
      checkpoint_date: formatIsoLocal(text(event.timestamp)),
      location,
      tracking_detail: withLocation(text(event.description) || text(event.status), location),
    };
  });
  const current = isObject(shipment.status) ? shipment.status : {};
  const location = locality(current.location);
  const latestEvent = withLocation(text(current.description) || text(current.status), location) || trackinfo[0]?.tracking_detail || "運送中";
  return {
    status: DHL_STATUS[text(current.statusCode)] ?? "transit",
    latest_event: latestEvent,
    latest_time: formatIsoLocal(text(current.timestamp)) || trackinfo[0]?.checkpoint_date || "",
    trackinfo,
    live: true,
  };
}

const TRACK17_STATUS: Record<string, string> = {
  delivered: "delivered",
  inforeceived: "pickup",
  pickup: "pickup",
  intransit: "transit",
  outfordelivery: "transit",
  availableforpickup: "transit",
  exception: "exception",
  deliveryfailure: "exception",
  expired: "exception",
  alert: "exception",
  notfound: "notfound",
};

/** 17TRACK's track_info (API v2.2; the same shape the script read from 17TRACK's website). */
export function parse17Track(trackInfo: unknown): TrackResult | null {
  if (!isObject(trackInfo)) return null;
  const latestStatus = isObject(trackInfo.latest_status) ? text(trackInfo.latest_status.status) : "";
  const latest = isObject(trackInfo.latest_event) ? trackInfo.latest_event : {};
  const time = (event: Json) => {
    const raw = isObject(event.time_raw) ? event.time_raw : {};
    if (text(raw.date) && text(raw.time)) return `${text(raw.date)} ${text(raw.time)}`;
    return formatIsoLocal(text(event.time_iso));
  };
  const trackinfo: TrackNode[] = [];
  const providers = isObject(trackInfo.tracking) && Array.isArray(trackInfo.tracking.providers) ? trackInfo.tracking.providers : [];
  for (const provider of providers.filter(isObject)) {
    for (const event of (Array.isArray(provider.events) ? provider.events : []).filter(isObject)) {
      const location = text(event.location);
      trackinfo.push({ checkpoint_date: time(event), location, tracking_detail: withLocation(text(event.description), location) });
    }
  }
  const description = text(latest.description) || latestStatus;
  if (!description && !trackinfo.length) return null;
  return {
    status: TRACK17_STATUS[latestStatus.toLowerCase()] ?? "transit",
    latest_event: withLocation(description || "運送中", text(latest.location)),
    latest_time: time(latest) || trackinfo[0]?.checkpoint_date || "",
    trackinfo,
    live: true,
  };
}

/** Asks each courier's source; never throws (a failed request is a `live: false` result). */
export class Trackers {
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => Date;

  constructor(private readonly options: TrackerOptions = {}) {
    this.fetchImpl = options.fetch ?? fetch;
    this.now = options.now ?? (() => new Date());
  }

  /** Which couriers have a live source with this configuration. */
  get sources(): { dhl: boolean; track17: boolean } {
    return { dhl: Boolean(this.options.dhlApiKey), track17: Boolean(this.options.track17ApiKey) };
  }

  private nowText(): string {
    return formatNow(this.now(), this.options.timeZone);
  }

  /** The "check on the courier's site" result used when no source answers. */
  fallback(courierCode: string, message?: string): TrackResult {
    return {
      status: "transit",
      latest_event: message ?? `【${courierName(courierCode)}】單號已記錄（點擊 [查件] 查看即時進度）`,
      latest_time: this.nowText(),
      trackinfo: [],
      live: false,
    };
  }

  async track(courierCode: string, rawNumber: string): Promise<TrackResult> {
    const number = rawNumber.trim();
    const code = courierCode.toLowerCase();
    const source = courierFor(code)?.source ?? "17track";
    try {
      if (source === "tcat") return await this.tcat(number);
      if (source === "sf") return (await this.sf(number)) ?? this.fallback(code, "順豐單號追蹤中（點擊 [查件] 查看即時進度）");
      if (source === "dhl" && this.options.dhlApiKey) return (await this.dhl(number)) ?? this.fallback(code);
      if (this.options.track17ApiKey) return await this.track17(code, number);
      return this.fallback(code);
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      return { ...this.fallback(code, `查詢連線失敗：${reason.slice(0, 120)}`), status: "pending" };
    }
  }

  private async get(url: string, headers: Record<string, string> = {}): Promise<Response> {
    return this.fetchImpl(url, { headers: { ...HEADERS, ...headers }, signal: AbortSignal.timeout(TIMEOUT_MS) });
  }

  private async tcat(number: string): Promise<TrackResult> {
    const response = await this.get(`https://www.t-cat.com.tw/Inquire/TraceDetail.aspx?BillID=${encodeURIComponent(number)}`);
    if (!response.ok) throw new Error(`黑貓網站回應 HTTP ${response.status}`);
    return parseTcat(await response.text(), number, this.nowText());
  }

  private async sf(number: string): Promise<TrackResult | null> {
    const response = await this.get(
      `https://www.sf-express.com/sf-service-core-web/service/bills/${encodeURIComponent(number)}/routes?lang=sc&region=tw&translate=`,
      { Accept: "application/json" },
    );
    if (!response.ok) return null;
    return parseSf(await response.json().catch(() => null));
  }

  private async dhl(number: string): Promise<TrackResult | null> {
    const response = await this.get(`https://api-eu.dhl.com/track/shipments?trackingNumber=${encodeURIComponent(number)}&language=zh`, {
      "DHL-API-Key": this.options.dhlApiKey ?? "",
      Accept: "application/json",
    });
    if (response.status === 404) return { ...this.fallback("dhl", "DHL 查無此單號（可能尚未收件）"), status: "notfound", live: true };
    if (!response.ok) throw new Error(`DHL API 回應 HTTP ${response.status}`);
    return parseDhl(await response.json());
  }

  /** gettrackinfo; a number 17TRACK doesn't follow yet is registered first and reads "check again later". */
  private async track17(code: string, number: string): Promise<TrackResult> {
    const post = async (path: string) => {
      const response = await this.fetchImpl(`https://api.17track.net/track/v2.2/${path}`, {
        method: "POST",
        headers: { "17token": this.options.track17ApiKey ?? "", "Content-Type": "application/json" },
        body: JSON.stringify([{ number }]),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (!response.ok) throw new Error(`17TRACK API 回應 HTTP ${response.status}`);
      const json: unknown = await response.json();
      return isObject(json) && isObject(json.data) ? json.data : {};
    };
    const data = await post("gettrackinfo");
    const accepted = (Array.isArray(data.accepted) ? data.accepted : []).filter(isObject);
    const parsed = parse17Track(accepted.find((item) => text(item.number) === number)?.track_info);
    if (parsed) return parsed;
    await post("register");
    return this.fallback(code, `【${courierName(code)}】已交給 17TRACK 追蹤，稍後刷新即可看到軌跡`);
  }
}
