import request from "supertest";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { API_KEY, AUTH, setup } from "./helpers.js";

describe("auth", () => {
  it("serves /health without a key", async () => {
    const { app } = await setup();
    const res = await request(app).get("/health").expect(200);
    const database = process.env.TEST_DATABASE_URL ? "postgres" : "memory";
    expect(res.body).toEqual({ status: "ok", version: "1.0.0", database, jev: false });
  });

  it("rejects /v1 requests without a key", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/templates").expect(401);
    expect(res.body).toEqual({ error: { code: "unauthorized", message: expect.any(String) } });
    expect(res.headers["www-authenticate"]).toContain("Bearer");
  });

  it("rejects a wrong key", async () => {
    const { app } = await setup();
    await request(app).get("/v1/templates").set("Authorization", "Bearer nope").expect(401);
    await request(app).get("/v1/templates").query({ api_key: "nope" }).expect(401);
    await request(app).get("/v1/templates").set("Authorization", `Basic ${API_KEY}`).expect(401);
  });

  it("accepts a bearer key or the api_key query parameter", async () => {
    const { app } = await setup();
    await request(app).get("/v1/templates").set(AUTH).expect(200);
    await request(app).get("/v1/templates").query({ api_key: API_KEY }).expect(200);
  });

  it("accepts any of several configured keys", async () => {
    const { app } = await setup({ apiKeys: ["first", "second"] });
    await request(app).get("/v1/templates").set("Authorization", "Bearer second").expect(200);
    await request(app).get("/v1/templates").set("Authorization", "Bearer first").expect(200);
  });

  it("protects /mcp and /v1/openapi.json", async () => {
    const { app } = await setup();
    await request(app).post("/mcp").send({ jsonrpc: "2.0", id: 1, method: "tools/list" }).expect(401);
    await request(app).get("/v1/openapi.json").expect(401);
  });

  it("returns JSON errors for unknown routes and bad JSON", async () => {
    const { app } = await setup();
    const missing = await request(app).get("/nope").expect(404);
    expect(missing.body.error.code).toBe("not_found");
    const bad = await request(app)
      .put("/v1/templates/x")
      .set(AUTH)
      .set("Content-Type", "application/json")
      .send("{not json")
      .expect(400);
    expect(bad.body.error.code).toBe("invalid_json");
  });
});

describe("config", () => {
  const quiet = { warn() {} };

  it("refuses to start without API_KEYS outside test mode", () => {
    expect(() => loadConfig({ NODE_ENV: "production" }, quiet)).toThrow(/API_KEYS/);
  });

  it("allows no keys with ALLOW_NO_AUTH=1 or NODE_ENV=test", () => {
    expect(loadConfig({ NODE_ENV: "production", ALLOW_NO_AUTH: "1" }, quiet).apiKeys).toEqual([]);
    expect(loadConfig({ NODE_ENV: "test" }, quiet).apiKeys).toEqual([]);
  });

  it("parses keys, port and Jev settings", () => {
    const config = loadConfig(
      { NODE_ENV: "production", API_KEYS: " a, b ,,c ", PORT: "8080", TYPESAFE_API_KEY: "ts" },
      quiet,
    );
    expect(config).toMatchObject({ apiKeys: ["a", "b", "c"], port: 8080, jevApiKey: "ts", jevModel: "jev-latest" });
    expect(config.databaseUrl).toBeUndefined();
  });
});
