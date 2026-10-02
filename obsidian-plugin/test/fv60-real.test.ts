import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { prepareRecord, serializeJsonArray, upsertIntoJsonText, type UpsertOptions } from "../src/json-export";

const OPTS: UpsertOptions = { preserveFields: ["docNo", "done"], doneField: "done" };

/** 伺服器與 App 實際使用的 FV60 海運樣板（server/templates/managed/fv60_sea.json）。 */
const seaTemplate = JSON.parse(readFileSync(new URL("../../server/templates/managed/fv60_sea.json", import.meta.url), "utf8"));

/** 使用者紀錄檔中已過帳的一筆（2026-09-29 JT2609245）。 */
const postedRecord = {
	id: "mum0pp8glsq",
	date: "2026-09-29",
	supplier: "800000",
	supplierName: "義佳有限公司",
	osat: "ATK",
	caseNo: "JT2609245",
	billNo: "E1509025",
	invoice: "FR83150095 / ED17531542 / ED17316531",
	invDate: "2026-09-29",
	amount: 11718,
	expenseAmount: 11160,
	isMultiItem: true,
	taxItems: [{ name: "樂爾幸泛通世", invDate: "2026-09-09", invoice: "FR83150095", taxId: "28006223", taxBase: 9660, taxAmount: 483 }],
	qty: 34841,
	price: 0.336,
	text: "出口/ATK/JT2609245",
	docNo: "2200027093",
	done: true,
};

describe("FV60 record file", () => {
	const existing = serializeJsonArray([postedRecord]);
	const scanned = { ...seaTemplate.sample, id: "mup1abcd123", caseNo: "JT2610001", docNo: "", done: false };

	it("inserts a scanned FV60 record at the top with the template's key order", () => {
		const prepared = prepareRecord({ id: "SCAN-1", data: scanned });
		expect(prepared).not.toBeNull();
		const result = upsertIntoJsonText(existing, prepared!, OPTS);
		expect(result.outcome).toBe("created");
		const array = JSON.parse(result.text!);
		expect(array).toHaveLength(2);
		expect(array[0].caseNo).toBe("JT2610001");
		expect(Object.keys(array[0])).toEqual(Object.keys(seaTemplate.sample));
		expect(array[1]).toEqual(postedRecord);
		// 與使用者檔案相同的格式：兩個空白縮排、中文不跳脫
		expect(result.text).toContain('\n  {\n    "id": "mup1abcd123",');
		expect(result.text).toContain('"supplierName": "義佳有限公司"');
	});

	it("keeps docNo when re-synced before posting and never touches posted records", () => {
		const prepared = prepareRecord({ id: "SCAN-1", data: scanned })!;
		const first = upsertIntoJsonText(existing, prepared, OPTS).text!;
		const userFilled = first.replace('"docNo": ""', '"docNo": "2200099999"');
		const corrected = prepareRecord({ id: "SCAN-1", data: { ...scanned, qty: 40000 } })!;
		const second = upsertIntoJsonText(userFilled, corrected, OPTS);
		expect(second.outcome).toBe("updated");
		const array = JSON.parse(second.text!);
		expect(array[0].qty).toBe(40000);
		expect(array[0].docNo).toBe("2200099999");

		const touchPosted = prepareRecord({ id: "OLD", data: { ...postedRecord, amount: 1 } })!;
		expect(upsertIntoJsonText(existing, touchPosted, OPTS).outcome).toBe("skipped");
	});
});
