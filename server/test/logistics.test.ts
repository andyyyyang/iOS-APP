import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { parseRefreshMinutes } from "../src/config.js";
import { guessCourier, trackingUrl } from "../src/logistics/couriers.js";
import { DEFAULT_WATCHLIST_PATH, LogisticsService, applyResult, normalizeItem, parseWatchlist, type WatchItem } from "../src/logistics/service.js";
import {
  Trackers,
  formatCheckpointTime,
  formatNow,
  parse17Track,
  parseDhl,
  parseSf,
  parseTcat,
  tcatStatus,
  type TrackResult,
} from "../src/logistics/trackers.js";
import { VaultChangeFeed } from "../src/services/vault-changes.js";
import { VaultIndexService } from "../src/services/vault-index.js";
import { VaultService } from "../src/services/vault.js";
import { MemoryVaultStore } from "../src/vault/memory.js";
import { AUTH, setup, silentLogger } from "./helpers.js";

const fixture = (name: string) => readFileSync(fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url)), "utf8");
const NOW = new Date("2026-10-15T01:02:00Z"); // 09:02 in Taipei

describe("tracker parsers", () => {
  it("reads T-Cat's trace table like the Python script", () => {
    const result = parseTcat(fixture("tcat-trace.html"), "909556582781", "2026-10-15 09:02");
    expect(result.status).toBe("delivered");
    expect(result.latest_event).toBe("順利送達 [北高營業所]");
    expect(result.latest_time).toBe("2026/10/05 15:40");
    expect(result.trackinfo).toHaveLength(8);
    expect(result.trackinfo[1]).toEqual({ checkpoint_date: "2026/10/05 09:17", location: "北高營業所", tracking_detail: "不在家 [北高營業所]" });
    expect(result.live).toBe(true);

    expect(parseTcat(fixture("tcat-none.html"), "900000000001", "2026-10-15 09:02")).toEqual({
      status: "notfound",
      latest_event: "黑貓系統尚無此單號節點記錄",
      latest_time: "2026-10-15 09:02",
      trackinfo: [],
      live: true,
    });
    expect(parseTcat("<html>maintenance</html>", "1", "t").latest_event).toBe("黑貓系統查無此單號狀態（資料處理中或尚未收件）");
    expect(["順利送達", "已集運", "退件中", "配送中"].map(tcatStatus)).toEqual(["delivered", "pickup", "exception", "transit"]);
    expect(formatCheckpointTime("2026/10/0515:40")).toBe("2026/10/05 15:40");
    expect(formatNow(NOW)).toBe("2026-10-15 09:02");
  });

  it("reads SF routes, DHL's tracking API and 17TRACK's track_info", () => {
    expect(
      parseSf({
        success: true,
        data: { routes: [{ scanDateTime: "2026-10-14 18:00", stayCity: "桃園", remark: "已簽收" }, { scanDateTime: "2026-10-13 09:00", stayCity: "深圳", remark: "已收取快件" }] },
      }),
    ).toMatchObject({ status: "delivered", latest_event: "已簽收", latest_time: "2026-10-14 18:00", live: true });
    expect(parseSf({ success: true, data: { routes: [] } })).toBeNull();
    expect(parseSf({ success: false })).toBeNull();

    const dhl = parseDhl({
      shipments: [
        {
          id: "1234567890",
          status: { timestamp: "2026-10-14T10:20:00+08:00", location: { address: { addressLocality: "TAIPEI - TAIWAN" } }, statusCode: "transit", description: "Arrived at Delivery Facility" },
          events: [
            { timestamp: "2026-10-14T10:20:00+08:00", location: { address: { addressLocality: "TAIPEI - TAIWAN" } }, description: "Arrived at Delivery Facility" },
            { timestamp: "2026-10-13T22:05:00+09:00", location: { address: { addressLocality: "TOKYO - JAPAN" } }, description: "Departed Facility" },
          ],
        },
      ],
    });
    expect(dhl).toMatchObject({ status: "transit", latest_event: "Arrived at Delivery Facility [TAIPEI - TAIWAN]", latest_time: "2026-10-14 10:20" });
    expect(dhl!.trackinfo[1]).toEqual({ checkpoint_date: "2026-10-13 22:05", location: "TOKYO - JAPAN", tracking_detail: "Departed Facility [TOKYO - JAPAN]" });
    expect(parseDhl({ shipments: [{ status: { statusCode: "delivered", description: "Delivered" }, events: [] }] })!.status).toBe("delivered");

    const seventeen = parse17Track({
      latest_status: { status: "Delivered" },
      latest_event: { time_iso: "2026-10-12T15:00:00-04:00", description: "Delivered", location: "NEW YORK, NY" },
      tracking: { providers: [{ events: [{ time_iso: "2026-10-12T15:00:00-04:00", description: "Delivered", location: "NEW YORK, NY" }, { time_raw: { date: "2026-10-11", time: "08:00" }, description: "On FedEx vehicle", location: "" }] }] },
    });
    expect(seventeen).toMatchObject({ status: "delivered", latest_event: "Delivered [NEW YORK, NY]", latest_time: "2026-10-12 15:00" });
    expect(seventeen!.trackinfo.map((node) => node.checkpoint_date)).toEqual(["2026-10-12 15:00", "2026-10-11 08:00"]);
    expect(parse17Track({})).toBeNull();
  });

  it("guesses couriers from the number and builds tracking links", () => {
    expect(["SF1234567890123", "1Z999AA10123456784", "1234567890", "909556582781", "784920194820", "abc"].map(guessCourier)).toEqual([
      "sf-express",
      "ups",
      "dhl",
      "t-cat",
      "fedex",
      null,
    ]);
    expect(trackingUrl("t-cat", "909556582781")).toBe("https://www.t-cat.com.tw/Inquire/Trace.aspx?BillID=909556582781");
    expect(trackingUrl("unknown", "X 1")).toBe("https://t.17track.net/zh-tw#nums=X%201");
  });
});

describe("Trackers (fake network)", () => {
  type Call = { url: string; init?: RequestInit };
  const fakeFetch = (respond: (call: Call) => Response | Promise<Response>) => {
    const calls: Call[] = [];
    const impl = (async (input: string | URL | Request, init?: RequestInit) => {
      const call = { url: String(input), init };
      calls.push(call);
      return respond(call);
    }) as typeof fetch;
    return { calls, impl };
  };
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

  it("asks T-Cat, falls back for SF, and only uses DHL and 17TRACK with their keys", async () => {
    const net = fakeFetch(({ url }) => {
      if (url.includes("t-cat.com.tw")) return new Response(fixture("tcat-trace.html"));
      if (url.includes("sf-express.com")) return json({ success: true, result: { status: 404 } }, 404);
      if (url.includes("api-eu.dhl.com")) return json({ shipments: [{ status: { statusCode: "delivered", description: "Delivered" }, events: [] }] });
      return json({ data: {} });
    });
    const plain = new Trackers({ fetch: net.impl, now: () => NOW });
    expect((await plain.track("t-cat", " 909556582781 ")).latest_event).toBe("順利送達 [北高營業所]");
    expect(net.calls[0]!.url).toBe("https://www.t-cat.com.tw/Inquire/TraceDetail.aspx?BillID=909556582781");
    expect(await plain.track("sf-express", "SF1")).toMatchObject({ live: false, latest_event: "順豐單號追蹤中（點擊 [查件] 查看即時進度）", latest_time: "2026-10-15 09:02" });
    expect(await plain.track("fedex", "784920194820")).toMatchObject({ live: false, latest_event: "【FedEx 聯邦快遞】單號已記錄（點擊 [查件] 查看即時進度）" });
    expect(await plain.track("dhl", "1234567890")).toMatchObject({ live: false });
    expect(net.calls.some((call) => call.url.includes("dhl.com"))).toBe(false);
    expect(plain.sources).toEqual({ dhl: false, track17: false });

    const keyed = new Trackers({ fetch: net.impl, dhlApiKey: "dhl-key", now: () => NOW });
    expect(await keyed.track("dhl", "1234567890")).toMatchObject({ status: "delivered", latest_event: "Delivered", live: true });
    const dhlCall = net.calls.find((call) => call.url.includes("api-eu.dhl.com"))!;
    expect((dhlCall.init!.headers as Record<string, string>)["DHL-API-Key"]).toBe("dhl-key");
  });

  it("registers an unknown number with 17TRACK, reads it later, and reports network failures", async () => {
    let registered = false;
    const net = fakeFetch(({ url }) => {
      if (url.endsWith("/register")) {
        registered = true;
        return json({ code: 0, data: { accepted: [{ number: "784920194820" }] } });
      }
      if (!registered) return json({ code: 0, data: { accepted: [], rejected: [{ number: "784920194820", error: { code: -18019902 } }] } });
      return json({
        code: 0,
        data: { accepted: [{ number: "784920194820", track_info: { latest_status: { status: "InTransit" }, latest_event: { time_iso: "2026-10-14T08:00:00+08:00", description: "In transit", location: "TAOYUAN" } } }] },
      });
    });
    const trackers = new Trackers({ fetch: net.impl, track17ApiKey: "17-key", now: () => NOW });
    expect(await trackers.track("fedex", "784920194820")).toMatchObject({ live: false, latest_event: "【FedEx 聯邦快遞】已交給 17TRACK 追蹤，稍後刷新即可看到軌跡" });
    expect(await trackers.track("fedex", "784920194820")).toMatchObject({ live: true, status: "transit", latest_event: "In transit [TAOYUAN]" });
    expect((net.calls[0]!.init!.headers as Record<string, string>)["17token"]).toBe("17-key");

    const offline = new Trackers({
      fetch: (async () => {
        throw new Error("getaddrinfo ENOTFOUND www.t-cat.com.tw");
      }) as typeof fetch,
      now: () => NOW,
    });
    expect(await offline.track("t-cat", "909556582781")).toMatchObject({ status: "pending", live: false, latest_event: "查詢連線失敗：getaddrinfo ENOTFOUND www.t-cat.com.tw" });
  });
});

/** A scripted tracker: results by number (default: a live "運送中" result). */
class FakeTrackers {
  readonly calls: string[] = [];
  readonly sources = { dhl: false, track17: false };
  constructor(private readonly results: Record<string, Partial<TrackResult>> = {}) {}
  async track(courier: string, number: string): Promise<TrackResult> {
    this.calls.push(`${courier}:${number}`);
    return { status: "transit", latest_event: `運送中 ${number}`, latest_time: "2026/10/15 08:00", trackinfo: [], live: true, ...this.results[number] };
  }
}

const DESKTOP_ITEMS = [
  {
    tracking_number: "909556582781",
    courier_code: "t-cat",
    courier_name: "黑貓宅急便",
    note: "",
    status: "transit",
    is_archived: false,
    latest_event: "配送中 [北高營業所]",
    latest_time: "2026/10/05 09:15",
    trackinfo: [{ checkpoint_date: "2026/10/05 09:15", location: "北高營業所", tracking_detail: "配送中 [北高營業所]" }],
    updated_at: "2026-10-05T09:20:00.000000",
    extra_desktop_field: 1,
  },
  { tracking_number: "SF0217035697020", courier_code: "sf-express", courier_name: "順豐速運", note: "test", status: "delivered", is_archived: true, latest_event: "已簽收", latest_time: "2026-09-17 13:10", trackinfo: [], updated_at: "" },
];

async function logisticsApp(files: Record<string, string>, trackers = new FakeTrackers()) {
  const store = new MemoryVaultStore();
  for (const [path, body] of Object.entries(files)) {
    await store.write(path, Buffer.from(body, "utf8"), { mtime: 1_760_000_000_000, contentType: "text/plain" });
  }
  const { app } = await setup({ vault: store, logistics: { trackers, gapMs: 0 }, now: () => NOW.getTime() });
  const watchlist = async () => JSON.parse((await store.read(DEFAULT_WATCHLIST_PATH))!.body.toString("utf8")) as WatchItem[];
  return { app, store, trackers, watchlist };
}

describe("/v1/logistics", () => {
  it("lists the desktop tool's watch list with couriers and statuses", async () => {
    const { app } = await logisticsApp({ [DEFAULT_WATCHLIST_PATH]: JSON.stringify(DESKTOP_ITEMS) });
    const res = await request(app).get("/v1/logistics").set(AUTH).expect(200);
    expect(res.body.items.map((item: WatchItem) => item.tracking_number)).toEqual(["909556582781", "SF0217035697020"]);
    expect(res.body.items[0].extra_desktop_field).toBe(1);
    expect(res.body.couriers.find((courier: { code: string }) => courier.code === "t-cat")).toMatchObject({ name: "黑貓宅急便", live: true });
    expect(res.body.couriers.find((courier: { code: string }) => courier.code === "fedex").live).toBe(false);
    expect(res.body.statuses.map((status: { id: string }) => status.id)).toContain("exception");
    expect(res.body).toMatchObject({ path: DEFAULT_WATCHLIST_PATH, dhl: false, track17: false, refresh: { intervalMinutes: 0, running: false } });

    const empty = await logisticsApp({});
    expect((await request(empty.app).get("/v1/logistics").set(AUTH).expect(200)).body.items).toEqual([]);
  });

  it("adds, edits, archives, restores and deletes items in the vault file", async () => {
    const { app, watchlist, trackers } = await logisticsApp({});
    const added = await request(app).post("/v1/logistics/items").set(AUTH).send({ courier: "T-CAT", number: " 9095 5658 2781 ", note: "中秋禮盒" }).expect(201);
    expect(added.body.item).toMatchObject({
      tracking_number: "909556582781",
      courier_code: "t-cat",
      courier_name: "黑貓宅急便",
      note: "中秋禮盒",
      status: "transit",
      is_archived: false,
      latest_event: "運送中 909556582781",
      updated_at: NOW.toISOString(),
    });
    expect(trackers.calls).toEqual(["t-cat:909556582781"]);
    await request(app).post("/v1/logistics/items").set(AUTH).send({ courier: "dhl", number: "1234567890" }).expect(201);
    // newest first, like the script's insert(0)
    expect((await watchlist()).map((item) => item.tracking_number)).toEqual(["1234567890", "909556582781"]);
    // adding the same number again keeps its note when none is given
    await request(app).post("/v1/logistics/items").set(AUTH).send({ courier: "t-cat", number: "909556582781" }).expect(201);
    expect((await watchlist()).find((item) => item.tracking_number === "909556582781")!.note).toBe("中秋禮盒");

    const edited = await request(app).patch("/v1/logistics/items/909556582781").set(AUTH).send({ note: " 改送公司 ", status: "exception" }).expect(200);
    expect(edited.body.item).toMatchObject({ note: "改送公司", status: "exception" });
    const archived = await request(app).patch("/v1/logistics/items/909556582781").set(AUTH).send({ archived: true }).expect(200);
    expect(archived.body.item).toMatchObject({ is_archived: true, status: "delivered" });
    const restored = await request(app).patch("/v1/logistics/items/909556582781").set(AUTH).send({ archived: false }).expect(200);
    expect(restored.body.item).toMatchObject({ is_archived: false, status: "transit" });

    await request(app).delete("/v1/logistics/items/1234567890").set(AUTH).expect(204);
    expect((await watchlist()).map((item) => item.tracking_number)).toEqual(["909556582781"]);
    await request(app).delete("/v1/logistics/items/1234567890").set(AUTH).expect(404);
    await request(app).patch("/v1/logistics/items/nope").set(AUTH).send({ note: "x" }).expect(404);
    await request(app).patch("/v1/logistics/items/909556582781").set(AUTH).send({}).expect(400);
    await request(app).patch("/v1/logistics/items/909556582781").set(AUTH).send({ status: "lost" }).expect(400);
    await request(app).post("/v1/logistics/items").set(AUTH).send({ courier: "t-cat", number: "a/b" }).expect(400);
    await request(app).post("/v1/logistics/items").set(AUTH).send({ number: "909556582781" }).expect(400);
  });

  it("refreshes one or all active items without losing progress to a failed lookup", async () => {
    const trackers = new FakeTrackers({
      "909556582781": { status: "delivered", latest_event: "順利送達 [北高營業所]", latest_time: "2026/10/05 15:40", trackinfo: [{ checkpoint_date: "2026/10/05 15:40", location: "北高營業所", tracking_detail: "順利送達 [北高營業所]" }] },
    });
    const { app, watchlist } = await logisticsApp({ [DEFAULT_WATCHLIST_PATH]: JSON.stringify(DESKTOP_ITEMS) }, trackers);
    const one = await request(app).post("/v1/logistics/items/909556582781/refresh").set(AUTH).expect(200);
    expect(one.body.item).toMatchObject({ status: "delivered", latest_event: "順利送達 [北高營業所]", extra_desktop_field: 1 });
    expect(one.body.item.trackinfo).toHaveLength(1);
    await request(app).post("/v1/logistics/items/nope/refresh").set(AUTH).expect(404);

    trackers.calls.length = 0;
    const all = await request(app).post("/v1/logistics/refresh").set(AUTH).expect(200);
    expect(all.body.refreshed).toBe(1); // the archived SF item is not tracked any more
    expect(trackers.calls).toEqual(["t-cat:909556582781"]);
    expect((await request(app).get("/v1/logistics").set(AUTH).expect(200)).body.refresh).toMatchObject({ lastRunAt: NOW.toISOString(), lastRefreshed: 1, lastError: null });

    const item = normalizeItem(DESKTOP_ITEMS[0]!);
    const failed: TrackResult = { status: "pending", latest_event: "查詢連線失敗：timeout", latest_time: "now", trackinfo: [], live: false };
    expect(applyResult(item, failed, "at")).toMatchObject({ status: "transit", latest_event: "配送中 [北高營業所]", updated_at: "at" });

    const archive = await request(app).post("/v1/logistics/archive-delivered").set(AUTH).expect(200);
    expect(archive.body).toEqual({ archived: 1 });
    expect((await request(app).post("/v1/logistics/archive-delivered").set(AUTH).expect(200)).body).toEqual({ archived: 0 });
    const cleared = await request(app).delete("/v1/logistics/archived").set(AUTH).expect(200);
    expect(cleared.body).toEqual({ removed: 2 });
    expect(await watchlist()).toEqual([]);
  });

  it("finds notes whose frontmatter names a tracking number", async () => {
    const { app } = await logisticsApp({
      [DEFAULT_WATCHLIST_PATH]: JSON.stringify(DESKTOP_ITEMS),
      "05 客戶案件/RFQ-2608-01.md": '---\ncustomer: Qualcomm\ncase_no: RFQ-2608-01\ntracking_no: "784920194820"\ncourier: fedex\n---\n# RFQ\n',
      "05 客戶案件/樣品寄送.md": "---\ntcat_no: 909556582781\n---\n樣品\n",
      "05 客戶案件/無單號.md": "---\ncustomer: X\n---\n",
      "05 客戶案件/SF.md": "---\nsf_no: SF1234567890123\n---\n",
    });
    const res = await request(app).get("/v1/logistics/linked").set(AUTH).expect(200);
    const byName = Object.fromEntries(res.body.notes.map((note: { name: string }) => [note.name, note]));
    expect(Object.keys(byName).sort()).toEqual(["RFQ-2608-01", "SF", "樣品寄送"]);
    expect(byName["RFQ-2608-01"]).toEqual({
      path: "05 客戶案件/RFQ-2608-01.md",
      name: "RFQ-2608-01",
      customer: "Qualcomm",
      caseNo: "RFQ-2608-01",
      trackingNumber: "784920194820",
      courier: "fedex",
      courierName: "FedEx 聯邦快遞",
      tracked: false,
    });
    expect(byName["樣品寄送"]).toMatchObject({ courier: "t-cat", tracked: true, caseNo: "樣品寄送" });
    expect(byName.SF).toMatchObject({ courier: "sf-express" });
  });

  it("answers 503 without a vault and refuses a watch list that is not an array", async () => {
    const { app } = await setup();
    await request(app).get("/v1/logistics").set(AUTH).expect(503);
    expect(() => parseWatchlist("{}")).toThrow(/array/);
    expect(() => parseWatchlist("{")).toThrow(/valid JSON/);
    expect(parseWatchlist("﻿  ")).toEqual([]);
    const broken = await logisticsApp({ [DEFAULT_WATCHLIST_PATH]: '{"a":1}' });
    expect((await request(broken.app).get("/v1/logistics").set(AUTH).expect(422)).body.error.code).toBe("invalid_watchlist");
  });
});

describe("logistics config", () => {
  it("reads LOGISTICS_REFRESH_MINUTES (default 120, 0 = off, at least 15)", () => {
    expect([undefined, "", "0", "5", "45"].map(parseRefreshMinutes)).toEqual([120, 120, 0, 15, 45]);
    expect(() => parseRefreshMinutes("soon")).toThrow(/LOGISTICS_REFRESH_MINUTES/);
    expect(() => parseRefreshMinutes("-1")).toThrow();
  });
});

describe("LogisticsService background refresh", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("refreshes a minute after start and then every interval; off without minutes or a vault", async () => {
    vi.useFakeTimers();
    const store = new MemoryVaultStore();
    await store.write(DEFAULT_WATCHLIST_PATH, Buffer.from(JSON.stringify(DESKTOP_ITEMS)), { mtime: 1, contentType: "application/json" });
    const changes = new VaultChangeFeed();
    const vault = new VaultService(store, null, changes);
    const vaultIndex = new VaultIndexService(vault, changes);
    const trackers = new FakeTrackers();
    const service = new LogisticsService({ vault, vaultIndex }, { trackers, refreshMinutes: 30, gapMs: 0, logger: silentLogger });
    service.start();
    await vi.advanceTimersByTimeAsync(59_000);
    expect(trackers.calls).toEqual([]);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(trackers.calls).toEqual(["t-cat:909556582781"]);
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(trackers.calls).toHaveLength(2);
    service.stop();
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(trackers.calls).toHaveLength(2);
    changes.close();

    const idle = new FakeTrackers();
    new LogisticsService({ vault, vaultIndex }, { trackers: idle }).start();
    const noVault = new VaultService(null, null, new VaultChangeFeed());
    new LogisticsService({ vault: noVault, vaultIndex: new VaultIndexService(noVault, new VaultChangeFeed()) }, { trackers: idle, refreshMinutes: 15 }).start();
    await vi.advanceTimersByTimeAsync(2 * 60 * 60_000);
    expect(idle.calls).toEqual([]);
  });
});
