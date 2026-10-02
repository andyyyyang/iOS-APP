import request from "supertest";
import { describe, expect, it } from "vitest";
import { BUILTIN_TEMPLATES } from "../src/templates/builtin.js";
import { validateAgainstSample } from "../src/validate.js";
import { AUTH, setup } from "./helpers.js";

const receiptSample = BUILTIN_TEMPLATES.find((t) => t.id === "receipt")!.sample;
const validReceipt = {
  store: "全聯福利中心",
  date: "2026-10-02",
  time: "14:30",
  items: [{ name: "鮮乳", quantity: 1, price: 45 }],
  subtotal: 45,
  tax: 0,
  total: 45,
  currency: "TWD",
  paymentMethod: "現金",
  invoiceNumber: "AB-12345678",
};

describe("validateAgainstSample", () => {
  it("accepts matching data", () => {
    expect(validateAgainstSample(validReceipt, receiptSample)).toEqual({ valid: true, issues: [] });
  });

  it("reports missing and unexpected keys", () => {
    const { tax: _tax, ...rest } = validReceipt;
    const result = validateAgainstSample({ ...rest, extra: 1 }, receiptSample);
    expect(result.valid).toBe(false);
    expect(result.issues).toEqual([
      { path: "$.tax", message: "Missing key" },
      { path: "$.extra", message: expect.stringContaining("Unexpected key") },
    ]);
  });

  it("treats helper keys starting with _ as optional inputs", () => {
    const sample = { qty: 1, _declarationQuantities: [1] };
    expect(validateAgainstSample({ qty: 34841 }, sample)).toEqual({ valid: true, issues: [] });
    expect(validateAgainstSample({ qty: 1, _declarationQuantities: ["x"] }, sample).issues).toEqual([
      { path: "$._declarationQuantities[0]", message: expect.stringContaining("Expected number") },
    ]);
  });

  it("reports wrong types", () => {
    const result = validateAgainstSample({ ...validReceipt, total: "45", items: {} }, receiptSample);
    expect(result.issues).toEqual([
      { path: "$.items", message: "Expected array, got object" },
      { path: "$.total", message: "Expected number, got string" },
    ]);
  });

  it("validates nested array elements against the first sample element", () => {
    const result = validateAgainstSample(
      { ...validReceipt, items: [{ name: "a", quantity: 1, price: 1 }, { name: "b", quantity: 2, price: "x" }, { name: "c", quantity: 1 }] },
      receiptSample,
    );
    expect(result.issues).toEqual([
      { path: "$.items[1].price", message: "Expected number, got string" },
      { path: "$.items[2].price", message: "Missing key" },
    ]);
  });

  it("always allows null in data; null in the sample means string or null", () => {
    const nulls = Object.fromEntries(Object.keys(validReceipt).map((k) => [k, null]));
    expect(validateAgainstSample(nulls, receiptSample).valid).toBe(true);
    expect(validateAgainstSample(null, receiptSample).valid).toBe(true);

    const sample = { note: null, tags: [] };
    expect(validateAgainstSample({ note: "hi", tags: [1, "a", { b: 2 }] }, sample).valid).toBe(true);
    expect(validateAgainstSample({ note: 5, tags: [] }, sample).issues).toEqual([
      { path: "$.note", message: "Expected string or null, got number" },
    ]);
  });

  it("formats non-identifier keys with brackets", () => {
    expect(validateAgainstSample({}, { "店 名": "x" }).issues[0]!.path).toBe('$["店 名"]');
  });
});

describe("POST /v1/validate", () => {
  it("validates against a stored template", async () => {
    const { app } = await setup();
    const ok = await request(app).post("/v1/validate").set(AUTH).send({ templateId: "receipt", data: validReceipt }).expect(200);
    expect(ok.body).toEqual({ valid: true, issues: [] });
    const bad = await request(app).post("/v1/validate").set(AUTH).send({ templateId: "receipt", data: { total: "1" } }).expect(200);
    expect(bad.body.valid).toBe(false);
    await request(app).post("/v1/validate").set(AUTH).send({ templateId: "nope", data: {} }).expect(404);
  });
});
