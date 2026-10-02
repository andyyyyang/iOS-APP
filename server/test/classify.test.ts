import { TypeSafeClient } from "@typesafe-ai/sdk";
import { fileURLToPath } from "node:url";
import request from "supertest";
import { describe, expect, it } from "vitest";
import { JevClassifier, truncateText } from "../src/classifier/jev.js";
import { ClassifierError } from "../src/classifier/types.js";
import { strongSignals } from "../src/classifier/signals.js";
import { AUTH, FakeClassifier, setup } from "./helpers.js";

const MANAGED = fileURLToPath(new URL("../templates/managed/", import.meta.url));

describe("POST /v1/classify", () => {
  it("passes the classifier result through", async () => {
    const result = {
      templateId: "receipt",
      confidence: 0.93,
      probabilities: { receipt: 0.93, business_card: 0.01, event: 0.01, document: 0.05 },
      provider: "jev",
    };
    const classifier = new FakeClassifier(() => result);
    const { app } = await setup({ classifier });
    const res = await request(app).post("/v1/classify").set(AUTH).send({ text: "全聯 合計 45" }).expect(200);
    expect(res.body).toEqual(result);
    expect(classifier.calls[0]!.text).toBe("全聯 合計 45");
    expect(classifier.calls[0]!.candidates.map((c) => c.id)).toEqual(["receipt", "business_card", "event", "document"]);
    expect(classifier.calls[0]!.candidates[0]!.description).toBe("購物收據、統一發票、消費明細，含商店、日期、品項與金額");

    const health = await request(app).get("/health").expect(200);
    expect(health.body.jev).toBe(true);
  });

  it("returns 503 jev_not_configured without a classifier", async () => {
    const { app } = await setup({ classifier: null });
    const res = await request(app).post("/v1/classify").set(AUTH).send({ text: "hello" }).expect(503);
    expect(res.body.error.code).toBe("jev_not_configured");
  });

  it("restricts criteria to templateIds", async () => {
    const classifier = new FakeClassifier();
    const { app } = await setup({ classifier });
    const res = await request(app)
      .post("/v1/classify")
      .set(AUTH)
      .send({ text: "會議紀錄", templateIds: ["document", "receipt"] })
      .expect(200);
    expect(classifier.calls[0]!.candidates.map((c) => c.id)).toEqual(["document", "receipt"]);
    expect(res.body.templateId).toBe("document");
    expect(Object.keys(res.body.probabilities)).toEqual(["document", "receipt"]);
  });

  it("rejects unknown templateIds and empty text", async () => {
    const { app } = await setup({ classifier: new FakeClassifier() });
    const unknown = await request(app)
      .post("/v1/classify")
      .set(AUTH)
      .send({ text: "x", templateIds: ["receipt", "nope"] })
      .expect(400);
    expect(unknown.body.error.code).toBe("unknown_template");
    await request(app).post("/v1/classify").set(AUTH).send({ text: "   " }).expect(400);
    await request(app).post("/v1/classify").set(AUTH).send({}).expect(400);
  });

  it("decides by a unique strong signal without calling the provider", async () => {
    const classifier = new FakeClassifier();
    const { app } = await setup({ classifier, managedTemplatesDir: MANAGED });
    const res = await request(app)
      .post("/v1/classify")
      .set(AUTH)
      .send({ text: "義佳國際物流股份有限公司\n統一編號 22368445\n請款單 合計 12,600" })
      .expect(200);
    expect(res.body).toEqual({ templateId: "fv60_sea", confidence: 1, probabilities: { fv60_sea: 1 }, provider: "keywords" });
    expect(classifier.calls).toHaveLength(0);

    // Signals from two templates are ambiguous: the provider decides.
    await request(app).post("/v1/classify").set(AUTH).send({ text: "萬泰物流 義佳" }).expect(200);
    expect(classifier.calls).toHaveLength(1);
  });

  it("uses strong signals even without Jev", async () => {
    const { app } = await setup({ classifier: null, managedTemplatesDir: MANAGED });
    const res = await request(app).post("/v1/classify").set(AUTH).send({ text: "萬泰物流 空運 AWB 123" }).expect(200);
    expect(res.body.templateId).toBe("fv60_air");
    expect(res.body.provider).toBe("keywords");
    await request(app).post("/v1/classify").set(AUTH).send({ text: "全聯 合計 45" }).expect(503);
  });

  it("maps provider failures to 502", async () => {
    const classifier = new FakeClassifier(() => {
      throw new ClassifierError("upstream down");
    });
    const { app } = await setup({ classifier });
    const res = await request(app).post("/v1/classify").set(AUTH).send({ text: "x" }).expect(502);
    expect(res.body.error.code).toBe("classifier_error");
  });
});

describe("JevClassifier", () => {
  it("sends the System One choice request and maps the answer (no network)", async () => {
    const requests: { url: string; body: any }[] = [];
    const client = new TypeSafeClient({
      apiKey: "test",
      logLevel: "off",
      retry: { maxRetries: 0 },
      fetch: async (url, init) => {
        requests.push({ url, body: JSON.parse(String(init?.body)) });
        return new Response(
          JSON.stringify({
            model: "jev-latest",
            answers: {
              template: { type: "choice", choice: "receipt", confidence: 0.93, probabilities: { receipt: 0.93, document: 0.07 } },
            },
            usage: { input_tokens: 1, output_tokens: 1 },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    });
    const jev = new JevClassifier({ apiKey: "test", model: "jev-latest", client });
    const longText = "合".repeat(9000);
    const result = await jev.classify(longText, [
      { id: "receipt", name: "收據", description: "購物收據" },
      { id: "document", name: "文件", description: "一般文件" },
    ]);

    expect(result).toEqual({ templateId: "receipt", confidence: 0.93, probabilities: { receipt: 0.93, document: 0.07 }, provider: "jev" });
    expect(requests[0]!.url).toBe("https://api.typesafe.ai/v1/systemone");
    const body = requests[0]!.body;
    expect(body.model).toBe("jev-latest");
    expect(body.state.document).toHaveLength(8000);
    expect(body.questions.template).toEqual({
      type: "choice",
      instructions: "這份文件屬於哪一種情境？",
      criteria: { receipt: "購物收據", document: "一般文件" },
    });
  });

  it("wraps API errors in ClassifierError", async () => {
    const client = new TypeSafeClient({
      apiKey: "test",
      logLevel: "off",
      retry: { maxRetries: 0 },
      fetch: async () => new Response(JSON.stringify({ error: "bad key" }), { status: 401 }),
    });
    const jev = new JevClassifier({ apiKey: "test", model: "jev-latest", client });
    await expect(jev.classify("x", [{ id: "a", name: "A", description: "a" }, { id: "b", name: "B", description: "b" }])).rejects.toBeInstanceOf(
      ClassifierError,
    );
  });

  it("truncates by code point", () => {
    expect(truncateText("abc", 2)).toBe("ab");
    expect(truncateText("😀😀😀", 2)).toBe("😀😀");
    expect(truncateText("short")).toBe("short");
  });
});

describe("strongSignals", () => {
  it("keeps only non-empty ! keywords without the prefix", () => {
    expect(strongSignals(["!義佳", "海運", "!", "!22368445"])).toEqual(["義佳", "22368445"]);
  });
});
