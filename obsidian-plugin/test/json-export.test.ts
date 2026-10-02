import { describe, expect, it } from "vitest";
import {
	JsonArrayError,
	findMapping,
	mergePreserved,
	parseFieldList,
	parseJsonArray,
	prepareRecord,
	recordIdOf,
	serializeJsonArray,
	upsertIntoJsonText,
	upsertRecord,
	type UpsertOptions,
} from "../src/json-export";

const OPTS: UpsertOptions = { preserveFields: ["docNo", "done"], doneField: "done" };

/** A record in the shape of `11 SOP/fv60-廠商請款-紀錄.json`. */
function fv60(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		id: "mum0takt3q2",
		type: "air",
		vendor: "長榮航空貨運",
		vendorCode: "100234",
		invoiceNo: "AB12345678",
		invoiceDate: "2026-10-01",
		awbNo: "695-12345675",
		amount: 12500,
		tax: 625,
		currency: "TWD",
		description: "空運費 10/01 TPE→LAX",
		docNo: "",
		done: false,
		...overrides,
	};
}

/** The user's existing file: newest first, 2-space indent, one record they added by hand. */
const EXISTING = serializeJsonArray([
	fv60({ id: "mum0zzzz9ab", vendor: "陽明海運", type: "sea", docNo: "5100001234", done: true }),
	{ id: "manual01", vendor: "手動輸入的廠商", amount: 1, docNo: "5100000001", done: false, note: "不要動我" },
]);

function scanWith(data: unknown, id = "6F1C9D0E-2B7A-4E43-9A57-5B1E9F0C2D11") {
	return { id, data };
}

describe("settings helpers", () => {
	it("parses field lists", () => {
		expect(parseFieldList("docNo, done")).toEqual(["docNo", "done"]);
		expect(parseFieldList(" docNo，done、memo; docNo\n")).toEqual(["docNo", "done", "memo"]);
		expect(parseFieldList("  ")).toEqual([]);
	});

	it("finds the first complete mapping for a template", () => {
		const mappings = [
			{ templateId: "fv60_air", filePath: "" },
			{ templateId: " fv60_air ", filePath: "11 SOP/fv60-廠商請款-紀錄.json" },
			{ templateId: "fv60_sea", filePath: "11 SOP/fv60-廠商請款-紀錄.json" },
		];
		expect(findMapping(mappings, "fv60_air")?.filePath).toBe("11 SOP/fv60-廠商請款-紀錄.json");
		expect(findMapping(mappings, "fv60_sea")?.templateId).toBe("fv60_sea");
		expect(findMapping(mappings, "receipt")).toBeNull();
		expect(findMapping(mappings, null)).toBeNull();
	});
});

describe("prepareRecord", () => {
	it("uses data as received, keeping key order and its id", () => {
		const prepared = prepareRecord(scanWith(fv60()));
		expect(prepared?.recordId).toBe("mum0takt3q2");
		expect(Object.keys(prepared!.record)).toEqual(Object.keys(fv60()));
	});

	it("uses the scan id when data has no id", () => {
		const { id: _omit, ...withoutId } = fv60();
		void _omit;
		const prepared = prepareRecord(scanWith(withoutId, "SCAN-1"));
		expect(prepared?.recordId).toBe("SCAN-1");
		expect(Object.keys(prepared!.record)[0]).toBe("id");
		expect(prepared!.record.id).toBe("SCAN-1");
		expect(Object.keys(prepared!.record).slice(1)).toEqual(Object.keys(withoutId));
	});

	it("fills an empty id in place", () => {
		const prepared = prepareRecord(scanWith({ type: "sea", id: "", amount: 1 }, "SCAN-2"));
		expect(prepared?.record).toEqual({ type: "sea", id: "SCAN-2", amount: 1 });
		expect(Object.keys(prepared!.record)).toEqual(["type", "id", "amount"]);
	});

	it("accepts numeric ids and rejects non-object data", () => {
		expect(prepareRecord(scanWith({ id: 42 }))?.recordId).toBe("42");
		expect(prepareRecord(scanWith(null))).toBeNull();
		expect(prepareRecord(scanWith([fv60()]))).toBeNull();
		expect(prepareRecord(scanWith("text"))).toBeNull();
		expect(recordIdOf("x")).toBeNull();
	});
});

describe("parseJsonArray / serializeJsonArray", () => {
	it("round-trips with 2-space indent and a trailing newline", () => {
		const text = serializeJsonArray([fv60()]);
		expect(text.startsWith('[\n  {\n    "id": "mum0takt3q2",\n    "type": "air",')).toBe(true);
		expect(text.endsWith("}\n]\n")).toBe(true);
		expect(parseJsonArray(text)).toEqual([fv60()]);
	});

	it("treats an empty file as an empty array", () => {
		expect(parseJsonArray("")).toEqual([]);
		expect(parseJsonArray(" \n")).toEqual([]);
		expect(parseJsonArray("\uFEFF[]")).toEqual([]);
	});

	it("rejects files that are not JSON arrays", () => {
		expect(() => parseJsonArray('{"records": []}', "a.json")).toThrow(JsonArrayError);
		expect(() => parseJsonArray('{"records": []}', "a.json")).toThrow("「a.json」的內容不是 JSON 陣列");
		expect(() => parseJsonArray("[1, 2,", "b.json")).toThrow("「b.json」不是有效的 JSON");
	});
});

describe("mergePreserved", () => {
	it("keeps existing values of preserved fields in the incoming key order", () => {
		const merged = mergePreserved(
			fv60({ docNo: "5100009999", done: false, amount: 1 }),
			fv60({ amount: 2 }),
			["docNo", "done"],
		);
		expect(merged).toEqual(fv60({ docNo: "5100009999", amount: 2 }));
		expect(Object.keys(merged)).toEqual(Object.keys(fv60()));
	});

	it("appends preserved fields the incoming record lacks and ignores missing ones", () => {
		const merged = mergePreserved({ id: "a", memo: "x" }, { id: "a", amount: 1 }, ["memo", "docNo"]);
		expect(merged).toEqual({ id: "a", amount: 1, memo: "x" });
		expect(Object.keys(merged)).toEqual(["id", "amount", "memo"]);
	});
});

describe("upsertRecord (FV60)", () => {
	const prepared = (data: Record<string, unknown>) => prepareRecord(scanWith(data))!;

	it("inserts a new record at index 0 (newest first)", () => {
		const array = parseJsonArray(EXISTING);
		const result = upsertRecord(array, prepared(fv60()), OPTS);
		expect(result.outcome).toBe("created");
		expect(result.index).toBe(0);
		expect(result.array).toHaveLength(3);
		expect(result.array[0]).toEqual(fv60());
		expect(result.array.slice(1)).toEqual(array);
		expect(array).toHaveLength(2); // input not mutated
	});

	it("updates in place but keeps docNo and done", () => {
		const start = parseJsonArray(upsertIntoJsonText(EXISTING, prepared(fv60()), OPTS).text!);
		// The user filled in the SAP document number (not posted yet).
		(start[0] as Record<string, unknown>).docNo = "5100004321";
		const updated = upsertRecord(start, prepared(fv60({ amount: 13000, tax: 650, docNo: "", done: false })), OPTS);
		expect(updated.outcome).toBe("updated");
		expect(updated.index).toBe(0);
		expect(updated.array[0]).toEqual(fv60({ amount: 13000, tax: 650, docNo: "5100004321", done: false }));
		expect(Object.keys(updated.array[0] as object)).toEqual(Object.keys(fv60()));
		expect(updated.array.slice(1)).toEqual(start.slice(1));
	});

	it("keeps the record's position when it is not first", () => {
		const array = [fv60({ id: "newer" }), fv60(), fv60({ id: "older" })];
		const result = upsertRecord(array, prepared(fv60({ amount: 1 })), OPTS);
		expect(result.outcome).toBe("updated");
		expect(result.index).toBe(1);
		expect((result.array[1] as Record<string, unknown>).amount).toBe(1);
		expect(result.array.map((r) => (r as Record<string, unknown>).id)).toEqual(["newer", "mum0takt3q2", "older"]);
	});

	it("skips records already marked done", () => {
		const array = parseJsonArray(EXISTING);
		const result = upsertRecord(array, prepared(fv60({ id: "mum0zzzz9ab", amount: 999 })), OPTS);
		expect(result.outcome).toBe("skipped");
		expect(result.array).toEqual(array);
	});

	it("treats any truthy done value as done and honours a custom done field", () => {
		const array = [fv60({ done: "yes" })];
		expect(upsertRecord(array, prepared(fv60({ amount: 1 })), OPTS).outcome).toBe("skipped");
		const posted = [fv60({ posted: true })];
		expect(upsertRecord(posted, prepared(fv60({ amount: 1 })), { ...OPTS, doneField: "posted" }).outcome).toBe(
			"skipped",
		);
		expect(upsertRecord(posted, prepared(fv60({ amount: 1 })), { ...OPTS, doneField: "" }).outcome).toBe("updated");
	});

	it("reports unchanged when nothing differs", () => {
		const array = [fv60({ docNo: "5100004321" })];
		expect(upsertRecord(array, prepared(fv60()), OPTS).outcome).toBe("unchanged");
	});

	it("never touches records with other ids, including hand-written ones", () => {
		const array = parseJsonArray(EXISTING);
		const result = upsertRecord(array, prepared({ id: "manual02", vendor: "x" }), OPTS);
		expect(result.outcome).toBe("created");
		expect(result.array[2]).toEqual(array[1]);
	});

	it("can find a record by a previous id", () => {
		const array = [{ id: "SCAN-1", amount: 1, docNo: "51", done: false }];
		const result = upsertRecord(array, prepared({ id: "newid", amount: 2, docNo: "", done: false }), OPTS, ["SCAN-1"]);
		expect(result.outcome).toBe("updated");
		expect(result.array).toEqual([{ id: "newid", amount: 2, docNo: "51", done: false }]);
	});

	it("uses the scan id for records without id, matching it on the next sync", () => {
		const { id: _omit, ...noId } = fv60();
		void _omit;
		const first = upsertIntoJsonText("[]", prepareRecord(scanWith(noId, "SCAN-9"))!, OPTS);
		expect(first.outcome).toBe("created");
		const array = parseJsonArray(first.text!);
		expect((array[0] as Record<string, unknown>).id).toBe("SCAN-9");
		const second = upsertRecord(array, prepareRecord(scanWith({ ...noId, amount: 1 }, "SCAN-9"))!, OPTS);
		expect(second.outcome).toBe("updated");
		expect(second.array).toHaveLength(1);
	});
});

describe("upsertIntoJsonText", () => {
	const record = prepareRecord(scanWith(fv60()))!;

	it("creates [record] for a missing file", () => {
		const result = upsertIntoJsonText(null, record, OPTS);
		expect(result).toEqual({ text: `${JSON.stringify([fv60()], null, 2)}\n`, outcome: "created" });
	});

	it("produces the whole array with JSON.stringify(array, null, 2) + newline", () => {
		const result = upsertIntoJsonText(EXISTING, record, OPTS);
		expect(result.outcome).toBe("created");
		expect(result.text).toBe(`${JSON.stringify([fv60(), ...parseJsonArray(EXISTING)], null, 2)}\n`);
	});

	it("returns null text when skipped or unchanged", () => {
		const once = upsertIntoJsonText(EXISTING, record, OPTS).text!;
		expect(upsertIntoJsonText(once, record, OPTS)).toEqual({ text: null, outcome: "unchanged" });
		const done = prepareRecord(scanWith(fv60({ id: "mum0zzzz9ab" })))!;
		expect(upsertIntoJsonText(EXISTING, done, OPTS)).toEqual({ text: null, outcome: "skipped" });
	});

	it("refuses to touch a file that is not a JSON array", () => {
		expect(() => upsertIntoJsonText('{"a": 1}\n', record, OPTS, [], "11 SOP/x.json")).toThrow(
			"「11 SOP/x.json」的內容不是 JSON 陣列，已略過，不會覆寫",
		);
		expect(() => upsertIntoJsonText("not json", record, OPTS)).toThrow(JsonArrayError);
	});

	it("writes into an empty file", () => {
		expect(upsertIntoJsonText("", record, OPTS).text).toBe(serializeJsonArray([fv60()]));
	});
});
