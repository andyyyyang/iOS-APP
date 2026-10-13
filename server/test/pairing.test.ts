import type { Express } from "express";
import request from "supertest";
import { describe, expect, it, vi } from "vitest";
import { loadConfig, parsePublicUrl } from "../src/config.js";
import { MAX_PAIRING_CODES_PER_KEY, PairingService, normalizePairingCode } from "../src/services/pairing.js";
import { MemoryVaultStore } from "../src/vault/index.js";
import { API_KEY, AUTH, setup } from "./helpers.js";

const CODE_PATTERN = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$/;
const START = Date.parse("2026-10-13T00:00:00.000Z");
const MINUTE = 60 * 1000;

/** An app whose clock only moves when the test says so. */
async function pairingApp(options: Parameters<typeof setup>[0] = {}) {
  const clock = { now: START };
  const { app } = await setup({ now: () => clock.now, ...options });
  return { app, clock };
}

function createCode(app: Express, body?: object, headers: Record<string, string> = AUTH) {
  const req = request(app).post("/v1/pairing").set(headers);
  return body === undefined ? req : req.send(body);
}

function claim(app: Express, code: unknown, ip = "203.0.113.7") {
  return request(app).post("/pair").set("X-Forwarded-For", ip).send({ code });
}

const INVALID = { error: { code: "invalid_code", message: "Invalid or expired pairing code" } };

describe("POST /v1/pairing", () => {
  it("creates an XXXX-XXXX code valid for 10 minutes with a pairUrl from the request host", async () => {
    const { app } = await pairingApp();
    const res = await createCode(app, { vaultName: "My Vault", notesFolder: "iPad 筆記" })
      .set("Host", "ocr.example.com")
      .set("X-Forwarded-Proto", "https")
      .expect(201);
    expect(res.body).toEqual({ code: expect.stringMatching(CODE_PATTERN), expiresAt: "2026-10-13T00:10:00.000Z", pairUrl: expect.any(String) });
    expect(res.body.pairUrl).toBe(`localocr://pair?server=https%3A%2F%2Focr.example.com&code=${res.body.code}`);
    expect(res.headers["cache-control"]).toBe("no-store");

    // the body is optional
    const bare = await createCode(app).expect(201);
    expect(bare.body.code).toMatch(CODE_PATTERN);
    expect(bare.body.code).not.toBe(res.body.code);
  });

  it("uses PUBLIC_URL for pairUrl when set", async () => {
    const { app } = await pairingApp({ publicUrl: "https://ocr.example.com" });
    const res = await createCode(app, {}).set("Host", "internal:8080").expect(201);
    expect(res.body.pairUrl).toBe(`localocr://pair?server=https%3A%2F%2Focr.example.com&code=${res.body.code}`);
  });

  it("requires the API key", async () => {
    const { app } = await pairingApp();
    const res = await createCode(app, {}, {}).expect(401);
    expect(res.body.error.code).toBe("unauthorized");
    await createCode(app, {}, { Authorization: "Bearer nope" }).expect(401);
  });

  it("validates vaultName and notesFolder", async () => {
    const { app } = await pairingApp();
    for (const body of [{ vaultName: "" }, { notesFolder: "x".repeat(201) }, { vaultName: 5 }]) {
      const res = await createCode(app, body).expect(400);
      expect(res.body.error.code).toBe("invalid_request");
    }
    await createCode(app, { vaultName: "x".repeat(200), notesFolder: null }).expect(201);
  });
});

describe("POST /pair", () => {
  it("returns the key that created the code plus vaultName and notesFolder, once", async () => {
    const { app } = await pairingApp({ apiKeys: ["first-key", "second-key"] });
    const created = await createCode(app, { vaultName: "My Vault", notesFolder: "iPad 筆記" }, { Authorization: "Bearer second-key" });

    const res = await claim(app, created.body.code).expect(200);
    expect(res.body).toEqual({ apiKey: "second-key", vaultName: "My Vault", notesFolder: "iPad 筆記" });
    expect(res.headers["cache-control"]).toBe("no-store");

    const again = await claim(app, created.body.code).expect(404);
    expect(again.body).toEqual(INVALID);
    expect(again.headers["cache-control"]).toBe("no-store");

    // the api_key query parameter identifies the key too; missing fields come back as null
    const viaQuery = await request(app).post("/v1/pairing").query({ api_key: "first-key" }).expect(201);
    expect((await claim(app, viaQuery.body.code).expect(200)).body).toEqual({ apiKey: "first-key", vaultName: null, notesFolder: null });
  });

  it("needs no API key", async () => {
    const { app } = await pairingApp();
    const created = await createCode(app, {});
    const res = await request(app).post("/pair").send({ code: created.body.code }).expect(200);
    expect(res.body.apiKey).toBe(API_KEY);
  });

  it("ignores case, spaces and hyphens", async () => {
    const { app } = await pairingApp();
    const codes: string[] = [];
    for (let i = 0; i < 4; i++) codes.push((await createCode(app, {})).body.code);
    const [lower, spaced, joined, padded] = codes as [string, string, string, string];

    await claim(app, lower.toLowerCase()).expect(200);
    await claim(app, `${spaced.slice(0, 4)} ${spaced.slice(5)}`).expect(200);
    await claim(app, joined.replace("-", "")).expect(200);
    await claim(app, ` ${padded.slice(0, 2)} ${padded.slice(2).toLowerCase()} `).expect(200);
  });

  it("rejects unknown, expired and malformed codes", async () => {
    const { app, clock } = await pairingApp();
    expect((await claim(app, "AAAA-AAAA").expect(404)).body).toEqual(INVALID);
    expect((await claim(app, "").expect(404)).body).toEqual(INVALID);

    const first = await createCode(app, {});
    const second = await createCode(app, {});
    clock.now = START + 10 * MINUTE - 1;
    await claim(app, first.body.code).expect(200);
    clock.now = START + 10 * MINUTE;
    expect((await claim(app, second.body.code).expect(404)).body).toEqual(INVALID);

    const missing = await request(app).post("/pair").send({}).expect(400);
    expect(missing.body.error.code).toBe("invalid_request");
    await request(app).post("/pair").send({ code: 12345678 }).expect(400);
    await request(app).post("/pair").set("Content-Type", "application/json").send("{bad").expect(400);
  });

  it("keeps at most 20 outstanding codes per key, dropping the oldest", async () => {
    const { app } = await pairingApp({ apiKeys: ["a-key", "b-key"] });
    const other = await createCode(app, {}, { Authorization: "Bearer b-key" });
    const codes: string[] = [];
    for (let i = 0; i <= MAX_PAIRING_CODES_PER_KEY; i++) {
      codes.push((await createCode(app, {}, { Authorization: "Bearer a-key" }).expect(201)).body.code);
    }
    await claim(app, codes[0]).expect(404);
    await claim(app, codes[1]).expect(200);
    await claim(app, codes.at(-1)).expect(200);
    expect((await claim(app, other.body.code).expect(200)).body.apiKey).toBe("b-key");
  });

  it("allows 10 attempts per IP per 10 minutes, then 429 until the window passes", async () => {
    const { app, clock } = await pairingApp();
    for (let i = 0; i < 10; i++) {
      clock.now = START + i * 1000;
      await claim(app, "AAAA-AAAA").expect(404);
    }
    const limited = await claim(app, "AAAA-AAAA").expect(429);
    expect(limited.body).toEqual({ error: { code: "rate_limited", message: expect.any(String) } });
    expect(limited.headers["retry-after"]).toBe("591");
    expect(limited.headers["cache-control"]).toBe("no-store");

    // a valid code does not get through either, but other clients still can
    const created = await createCode(app, {});
    await claim(app, created.body.code).expect(429);
    await claim(app, "AAAA-AAAA", "198.51.100.1").expect(404);

    // the oldest attempt leaves the window after 10 minutes
    clock.now = START + 10 * MINUTE;
    await claim(app, "AAAA-AAAA").expect(404);
    await claim(app, created.body.code).expect(429);
    clock.now = START + 10 * MINUTE + 1000;
    await claim(app, created.body.code).expect(200);
  });

  it("hands out whatever key was sent when auth is disabled", async () => {
    const { app } = await pairingApp({ apiKeys: [] });
    const created = await createCode(app, {}, { Authorization: "Bearer dev-key" });
    expect((await claim(app, created.body.code).expect(200)).body.apiKey).toBe("dev-key");
  });

  it("never logs the API key or the bucket keys", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) =>
      vi.spyOn(console, method).mockImplementation(() => {}),
    );
    try {
      const vaultConfig = {
        endpoint: "https://t3.storageapi.dev",
        bucket: "obsidian-vault-abc",
        region: "auto",
        accessKeyId: "tid_SECRET_ID",
        secretAccessKey: "tsec_SECRET_VALUE",
        forcePathStyle: false,
        prefix: "",
      };
      const { app } = await pairingApp({ apiKeys: ["pairing-SECRET-key"], vault: new MemoryVaultStore(), vaultConfig });
      const auth = { Authorization: "Bearer pairing-SECRET-key" };
      const created = await createCode(app, { vaultName: "V" }, auth).expect(201);
      await claim(app, created.body.code).expect(200);
      await claim(app, created.body.code).expect(404);
      await request(app).get("/v1/vault/remotely-save").query({ vault: "V" }).set(auth).expect(200);

      const logged = JSON.stringify(spies.flatMap((spy) => spy.mock.calls));
      for (const secret of ["pairing-SECRET-key", "tid_SECRET_ID", "tsec_SECRET_VALUE", created.body.code]) {
        expect(logged).not.toContain(secret);
      }
    } finally {
      for (const spy of spies) spy.mockRestore();
    }
  });

  it("is described in OpenAPI", async () => {
    const { app } = await pairingApp();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    expect(res.body.paths["/v1/pairing"].post).toBeDefined();
    expect(res.body.paths["/pair"].post.security).toEqual([]);
    expect(Object.keys(res.body.paths["/pair"].post.responses)).toEqual(expect.arrayContaining(["200", "404", "429"]));
    for (const name of ["PairingCreateRequest", "PairingCode", "PairClaimRequest", "PairClaim"]) {
      expect(res.body.components.schemas[name], name).toBeDefined();
    }
  });
});

describe("PairingService", () => {
  it("maps random bytes onto the 32-symbol alphabet and retries on collision", () => {
    const draws = [
      [0, 1, 2, 3, 28, 29, 30, 31],
      [0, 1, 2, 3, 28, 29, 30, 31],
      [32, 255, 8, 13, 23, 24, 7, 6],
    ];
    const pairing = new PairingService({ now: () => START, random: () => Uint8Array.from(draws.shift()!) });
    expect(pairing.create("k", {}).code).toBe("ABCD-6789");
    // the same bytes again would collide: a new draw is taken
    expect(pairing.create("k", {}).code).toBe("A9JP-Z2HG");
    expect(pairing.size).toBe(2);
  });

  it("prunes expired codes", () => {
    let now = START;
    const pairing = new PairingService({ now: () => now });
    pairing.create("k", {});
    now += 5 * MINUTE;
    pairing.create("k", {});
    expect(pairing.size).toBe(2);
    now = START + 10 * MINUTE;
    expect(pairing.size).toBe(1);
  });

  it("normalizes codes", () => {
    expect(normalizePairingCode(" ab-cd  ef gh ")).toBe("ABCDEFGH");
    expect(normalizePairingCode("abcd-efgh")).toBe("ABCDEFGH");
  });
});

describe("PUBLIC_URL", () => {
  it("is optional, loses trailing slashes and must be an http(s) URL", () => {
    expect(parsePublicUrl(undefined)).toBeUndefined();
    expect(parsePublicUrl("  ")).toBeUndefined();
    expect(parsePublicUrl("https://ocr.example.com/")).toBe("https://ocr.example.com");
    expect(() => parsePublicUrl("ocr.example.com")).toThrow(/PUBLIC_URL/);
    expect(() => parsePublicUrl("ftp://ocr.example.com")).toThrow(/PUBLIC_URL/);
    const quiet = { warn() {} };
    expect(loadConfig({ NODE_ENV: "test", PUBLIC_URL: "https://ocr.example.com" }, quiet).publicUrl).toBe("https://ocr.example.com");
    expect(loadConfig({ NODE_ENV: "test" }, quiet).publicUrl).toBeUndefined();
  });
});
