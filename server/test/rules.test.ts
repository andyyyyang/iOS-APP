import request from "supertest";
import { describe, expect, it } from "vitest";
import { AUTH, setup } from "./helpers.js";

const base = { name: "報關", description: "報關文件", sample: { items: [{ name: "", price: 0, category: null }], tax: 0, total: 0 } };
const rulesJson =
  '[{"value":0,"set":"tax","onlyIfEmpty":true},{"set":"total","sum":["items[].price"],"round":0},' +
  '{"set":"items[].category","lookup":"name","table":{"鮮乳":"飲品","麵包":"食品"}},' +
  '{"set":"title","template":"{store} {date}"},{"set":"joined","join":"items[].name","separator":"、"},' +
  '{"set":"ratio","divide":["total",2],"round":1},{"set":"date","today":true},{"set":"ref","generate":"base36time"}]';

describe("template rules", () => {
  it("returns an empty rules array for templates without rules", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/templates").set(AUTH).expect(200);
    for (const template of res.body.items) expect(template.rules).toEqual([]);
    const put = await request(app).put("/v1/templates/plain").set(AUTH).send(base).expect(201);
    expect(put.body.rules).toEqual([]);
  });

  it("round-trips rules with key order preserved (raw response text)", async () => {
    const { app } = await setup();
    const raw = `{"name":"報關","description":"報關文件","sample":{"total":0},"rules":${rulesJson}}`;
    const put = await request(app)
      .put("/v1/templates/customs")
      .set(AUTH)
      .set("Content-Type", "application/json")
      .send(raw)
      .expect(201);
    expect(put.text).toContain(`"rules":${rulesJson}`);

    const get = await request(app).get("/v1/templates/customs").set(AUTH).expect(200);
    expect(get.text).toContain(`"instructions":null,"rules":${rulesJson},"version":1`);
    const list = await request(app).get("/v1/templates").set(AUTH).expect(200);
    expect(list.text).toContain(`"rules":${rulesJson}`);
  });

  it("replaces rules on PUT; omitted or null means no rules", async () => {
    const { app } = await setup();
    await request(app).put("/v1/templates/customs").set(AUTH).send({ ...base, rules: JSON.parse(rulesJson) }).expect(201);
    const omitted = await request(app).put("/v1/templates/customs").set(AUTH).send(base).expect(200);
    expect(omitted.body).toMatchObject({ rules: [], version: 2 });
    await request(app).put("/v1/templates/customs").set(AUTH).send({ ...base, rules: [{ set: "tax", value: 5 }] }).expect(200);
    const nulled = await request(app).put("/v1/templates/customs").set(AUTH).send({ ...base, rules: null }).expect(200);
    expect(nulled.body).toMatchObject({ rules: [], version: 4 });
  });

  it("accepts up to 100 rules", async () => {
    const { app } = await setup();
    const rules = Array.from({ length: 100 }, (_, i) => ({ set: `f${i}`, value: i }));
    const res = await request(app).put("/v1/templates/many").set(AUTH).send({ ...base, rules }).expect(201);
    expect(res.body.rules).toHaveLength(100);
  });

  it.each([
    ["not an array", { set: "total", value: 1 }, /rules/],
    ["a string", "total=1", /rules/],
    ["a rule without set", [{ sum: ["items[].price"] }], /rules\.0\.set/],
    ["a non-string set", [{ set: 5, value: 1 }], /rules\.0\.set/],
    ["a non-object rule", ["total"], /rules\.0/],
    ["a nested path", [{ set: "a.b", value: 1 }], /rules\.0\.set.*field/],
    ["a bare array path", [{ set: "items[]", value: 1 }], /rules\.0\.set/],
    ["an empty set", [{ set: "", value: 1 }], /rules\.0\.set/],
    ["too many rules", Array.from({ length: 101 }, (_, i) => ({ set: `f${i}` })), /rules.*100/],
  ])("rejects rules that are %s", async (_label, rules, message) => {
    const { app } = await setup();
    const res = await request(app).put("/v1/templates/bad").set(AUTH).send({ ...base, rules }).expect(400);
    expect(res.body.error.code).toBe("invalid_request");
    expect(res.body.error.message).toMatch(message);
    await request(app).get("/v1/templates/bad").set(AUTH).expect(404);
  });

  it("documents rules in OpenAPI", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    const schemas = res.body.components.schemas;
    expect(schemas.Template.required).toContain("rules");
    expect(schemas.TemplateInput.properties.rules.maxItems).toBe(100);
    expect(schemas.TemplateRule.required).toEqual(["set"]);
    expect(new RegExp(schemas.TemplateRule.properties.set.pattern).test("items[].price")).toBe(true);
  });
});
