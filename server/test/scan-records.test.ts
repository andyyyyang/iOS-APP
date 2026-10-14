import request from "supertest";
import { describe, expect, it } from "vitest";
import { parseRecordOutputs, upsertRecord } from "../src/services/scan-records.js";
import { MemoryVaultStore } from "../src/vault/memory.js";
import { AUTH, randomScanId, scanBody, setup } from "./helpers.js";

const RECORDS = "11 SOP/fv60-廠商請款-紀錄.json";

const fv60 = (overrides: Record<string, unknown> = {}) => ({
  id: "mv4kwev160e",
  date: "2026-10-12",
  supplier: "801988",
  supplierName: "萬泰物流",
  osat: "ATK",
  caseNo: "JT2609258",
  billNo: "",
  invoice: "FR14077696",
  invDate: "2026-09-29",
  amount: 25242,
  expenseAmount: 25242,
  isMultiItem: false,
  taxItems: [],
  qty: 481913,
  price: 0.052,
  text: "出口/ATK/JT2609258",
  docNo: "",
  done: false,
  ...overrides,
});

async function vaultWith(files: Record<string, string>) {
  const vault = new MemoryVaultStore();
  for (const [path, body] of Object.entries(files)) {
    await vault.write(path, Buffer.from(body, "utf8"), { mtime: 1_760_000_000_000, contentType: "application/json" });
  }
  const { app } = await setup({ vault });
  const read = async () => JSON.parse((await vault.read(RECORDS))!.body.toString("utf8")) as Record<string, unknown>[];
  return { app, vault, read };
}

describe("scans → the FV60 record file", () => {
  it("adds a new FV60 scan first, as the record the FV60 tool expects", async () => {
    const older = { id: "old1", caseNo: "JT2600001", docNo: "2200000001", done: true };
    const { app, read } = await vaultWith({ [RECORDS]: JSON.stringify([older], null, 2) });
    await request(app).put(`/v1/scans/${randomScanId()}`).set(AUTH).send(scanBody({ templateId: "fv60_air", data: fv60() })).expect(201);
    const records = await read();
    expect(records.map((r) => r.id)).toEqual(["mv4kwev160e", "old1"]);
    expect(records[0]).toEqual(fv60());
    expect(records[1]).toEqual(older);
  });

  it("updates, skips finished records and leaves other files alone", async () => {
    const { app, vault, read } = await vaultWith({ [RECORDS]: "[]\n" });
    const id = randomScanId();
    const put = (data: Record<string, unknown>) =>
      request(app).put(`/v1/scans/${id}`).set(AUTH).send(scanBody({ templateId: "fv60_sea", data }));
    await put(fv60()).expect(201);
    expect((await read())[0]).toMatchObject({ id: "mv4kwev160e", amount: 25242 });

    // the FV60 tool saved a document number in the file
    const edited = await read();
    edited[0]!.docNo = "2200027566";
    await vault.write(RECORDS, Buffer.from(JSON.stringify(edited, null, 2), "utf8"), { mtime: Date.now(), contentType: "application/json" });

    await put(fv60({ amount: 25300 })).expect(200);
    expect((await read())[0]).toMatchObject({ amount: 25300, docNo: "2200027566" });

    // PATCH (data corrected in the app) updates as well
    await request(app).patch(`/v1/scans/${id}`).set(AUTH).send({ data: fv60({ amount: 25400 }) }).expect(200);
    expect((await read())[0]).toMatchObject({ amount: 25400, docNo: "2200027566" });

    // once done, the record is never changed again
    const finished = await read();
    finished[0]!.done = true;
    await vault.write(RECORDS, Buffer.from(JSON.stringify(finished, null, 2), "utf8"), { mtime: Date.now(), contentType: "application/json" });
    await put(fv60({ amount: 1 })).expect(200);
    expect((await read())[0]).toMatchObject({ amount: 25400, done: true });

    // other templates don't touch the file
    await request(app).put(`/v1/scans/${randomScanId()}`).set(AUTH).send(scanBody()).expect(201);
    expect(await read()).toHaveLength(1);
  });

  it("only writes into a record file that exists and is a JSON array", async () => {
    const empty = await vaultWith({});
    await request(empty.app).put(`/v1/scans/${randomScanId()}`).set(AUTH).send(scanBody({ templateId: "fv60_air", data: fv60() })).expect(201);
    expect(await empty.vault.read(RECORDS)).toBeNull();

    const broken = await vaultWith({ [RECORDS]: "{ not json" });
    await request(broken.app).put(`/v1/scans/${randomScanId()}`).set(AUTH).send(scanBody({ templateId: "fv60_air", data: fv60() })).expect(201);
    expect((await broken.vault.read(RECORDS))!.body.toString("utf8")).toBe("{ not json");
  });

  it("reads SCAN_RECORD_OUTPUTS", () => {
    expect(parseRecordOutputs(undefined).map((o) => o.templateId)).toEqual(["fv60_air", "fv60_sea"]);
    expect(parseRecordOutputs("off")).toEqual([]);
    expect(parseRecordOutputs("receipt=Finance/receipts.json; card=/People/cards.json")).toEqual([
      { templateId: "receipt", path: "Finance/receipts.json", preserve: ["docNo", "done"], doneField: "done", create: true },
      { templateId: "card", path: "People/cards.json", preserve: ["docNo", "done"], doneField: "done", create: true },
    ]);
  });

  it("matches records only by id", () => {
    const output = { preserve: ["docNo"], doneField: "done" };
    expect(upsertRecord([{ id: "a" }, { name: "no id" }], { record: { id: "b" }, id: "b" }, output).array).toEqual([
      { id: "b" },
      { id: "a" },
      { name: "no id" },
    ]);
    expect(upsertRecord([{ id: "scan-1", x: 1 }], { record: { id: "new", x: 2 }, id: "new" }, output, ["scan-1"])).toEqual({
      array: [{ id: "new", x: 2 }],
      outcome: "updated",
    });
  });
});
