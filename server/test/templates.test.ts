import request from "supertest";
import { describe, expect, it } from "vitest";
import { bootstrapStore } from "../src/bootstrap.js";
import { AUTH, setup } from "./helpers.js";

const order = (text: string, keys: string[]) => keys.map((key) => text.indexOf(`"${key}"`));
const isIncreasing = (values: number[]) => values.every((v, i) => v >= 0 && (i === 0 || v > values[i - 1]!));

describe("templates", () => {
  it("seeds the four built-in templates", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/templates").set(AUTH).expect(200);
    expect(res.body.items.map((t: { id: string }) => t.id)).toEqual(["receipt", "business_card", "event", "document"]);
    const receipt = res.body.items[0];
    expect(receipt).toMatchObject({
      name: "收據／發票",
      description: "購物收據、統一發票、消費明細，含商店、日期、品項與金額",
      version: 1,
      instructions: "金額使用數字；日期使用 YYYY-MM-DD；時間使用 24 小時制 HH:mm；找不到的欄位填 null。",
    });
    expect(receipt.keywords).toContain("統一編號");
    expect(Object.keys(receipt.sample)).toEqual([
      "store", "date", "time", "items", "subtotal", "tax", "total", "currency", "paymentMethod", "invoiceNumber",
    ]);
    expect(Object.keys(res.body.items[0])).toEqual([
      "id", "name", "description", "keywords", "sample", "instructions", "version", "updatedAt",
    ]);
  });

  it("does not overwrite user edits when seeding again", async () => {
    const { app, store } = await setup();
    await request(app)
      .put("/v1/templates/receipt")
      .set(AUTH)
      .send({ name: "我的收據", description: "自訂", sample: { total: 0 } })
      .expect(200);
    await bootstrapStore(store, { info() {} });
    const res = await request(app).get("/v1/templates/receipt").set(AUTH).expect(200);
    expect(res.body).toMatchObject({ name: "我的收據", version: 2, sample: { total: 0 } });
  });

  it("preserves sample key order through PUT/GET (raw response text)", async () => {
    const { app } = await setup();
    const raw =
      '{"name":"順序測試","description":"key order","sample":{"zeta":"z","alpha":1,"店名":null,"middle":{"b":true,"a":[{"y":1,"x":2}]},"beta":[]}}';
    const put = await request(app)
      .put("/v1/templates/order_test")
      .set(AUTH)
      .set("Content-Type", "application/json")
      .send(raw)
      .expect(201);
    expect(isIncreasing(order(put.text, ["zeta", "alpha", "店名", "middle", "b", "a", "y", "x", "beta"]))).toBe(true);

    const get = await request(app).get("/v1/templates/order_test").set(AUTH).expect(200);
    expect(get.text).toContain('"sample":{"zeta":"z","alpha":1,"店名":null,"middle":{"b":true,"a":[{"y":1,"x":2}]},"beta":[]}');

    const list = await request(app).get("/v1/templates").set(AUTH).expect(200);
    expect(list.text).toContain('{"zeta":"z","alpha":1,"店名":null,"middle":{"b":true,"a":[{"y":1,"x":2}]},"beta":[]}');
  });

  it("increments version and updatedAt on every PUT", async () => {
    const { app } = await setup();
    const body = { name: "菜單", description: "餐廳菜單", keywords: ["菜單"], sample: { dishes: [{ name: "", price: 0 }] } };
    const v1 = await request(app).put("/v1/templates/menu").set(AUTH).send(body).expect(201);
    expect(v1.body).toMatchObject({ id: "menu", version: 1, keywords: ["菜單"], instructions: null });
    const v2 = await request(app).put("/v1/templates/menu").set(AUTH).send({ ...body, instructions: "價格用數字" }).expect(200);
    expect(v2.body).toMatchObject({ version: 2, instructions: "價格用數字" });
    expect(Date.parse(v2.body.updatedAt)).toBeGreaterThan(Date.parse(v1.body.updatedAt));
    const v3 = await request(app).put("/v1/templates/menu").set(AUTH).send({ ...body, version: 99 }).expect(200);
    expect(v3.body.version).toBe(3);
  });

  it("validates ids and bodies", async () => {
    const { app } = await setup();
    const body = { name: "x", description: "y", sample: { a: 1 } };
    await request(app).put("/v1/templates/Bad_ID").set(AUTH).send(body).expect(400);
    await request(app).put("/v1/templates/-bad").set(AUTH).send(body).expect(400);
    await request(app).put("/v1/templates/ok").set(AUTH).send({ ...body, id: "other" }).expect(400);
    await request(app).put("/v1/templates/ok").set(AUTH).send({ ...body, sample: [1] }).expect(400);
    await request(app).put("/v1/templates/ok").set(AUTH).send({ ...body, name: "" }).expect(400);
    await request(app).put("/v1/templates/ok").set(AUTH).send({ name: "x", description: "y" }).expect(400);
  });

  it("deletes templates", async () => {
    const { app } = await setup();
    await request(app).delete("/v1/templates/event").set(AUTH).expect(204);
    await request(app).get("/v1/templates/event").set(AUTH).expect(404);
    await request(app).delete("/v1/templates/event").set(AUTH).expect(404);
    const res = await request(app).get("/v1/templates").set(AUTH).expect(200);
    expect(res.body.items).toHaveLength(3);
  });

  it("serves an OpenAPI 3.1 document", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    expect(res.body.openapi).toBe("3.1.0");
    expect(Object.keys(res.body.paths)).toEqual(
      expect.arrayContaining(["/v1/scans", "/v1/scans/{id}", "/v1/templates", "/v1/templates/{id}", "/v1/classify"]),
    );
    expect(res.body.components.securitySchemes.bearerAuth).toMatchObject({ type: "http", scheme: "bearer" });
  });
});
