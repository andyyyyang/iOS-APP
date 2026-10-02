import { describe, expect, it } from "vitest";
import {
	MARKER_END,
	MARKER_START,
	buildNotePath,
	deriveTitle,
	escapeFence,
	formatClock,
	formatDateTime,
	formatNoteTimestamp,
	mergeNote,
	normalizeFolder,
	parseFrontmatterBlocks,
	parseTagsBlock,
	renderBlock,
	renderNote,
	resolveTemplateName,
	sanitizeFileName,
	splitFrontmatter,
	uniquePath,
	withNumberSuffix,
	yamlScalar,
} from "../src/format";
import type { Scan } from "../src/types";

/** The example scan from docs/API.md. */
function exampleScan(overrides: Partial<Scan> = {}): Scan {
	return {
		id: "6F1C9D0E-2B7A-4E43-9A57-5B1E9F0C2D11",
		createdAt: "2026-10-02T03:10:00.000Z",
		updatedAt: "2026-10-02T03:10:02.000Z",
		source: "camera",
		text: "全聯福利中心\n鮮乳 45\n合計 45",
		templateId: "receipt",
		classification: {
			templateId: "receipt",
			confidence: 0.93,
			provider: "jev",
			probabilities: { receipt: 0.93, document: 0.05, business_card: 0.02 },
		},
		data: {
			store: "全聯福利中心",
			date: null,
			items: [{ name: "鮮乳", quantity: 1, price: 45 }],
			total: 45,
			currency: "TWD",
		},
		lineCount: 3,
		averageConfidence: 0.91,
		pageCount: 1,
		device: "iPhone",
		...overrides,
	};
}

const RECEIPT_OPTS = { templateName: "收據／發票", includeText: true };

describe("deriveTitle", () => {
	it("prefers title, then store, name, company", () => {
		expect(deriveTitle({ data: { company: "C", name: "N", store: "S", title: "T" }, text: "x" })).toBe("T");
		expect(deriveTitle({ data: { company: "C", name: "N", store: "S" }, text: "x" })).toBe("S");
		expect(deriveTitle({ data: { company: "C", name: "N" }, text: "x" })).toBe("N");
		expect(deriveTitle({ data: { company: "C" }, text: "x" })).toBe("C");
	});

	it("skips empty and non-string values", () => {
		expect(deriveTitle({ data: { title: "  ", store: null, name: { a: 1 }, company: "Acme  Inc" }, text: "" })).toBe(
			"Acme Inc",
		);
		expect(deriveTitle({ data: { title: 2026 }, text: "" })).toBe("2026");
	});

	it("falls back to the first non-empty line of text", () => {
		expect(deriveTitle({ data: { total: 45 }, text: "\n   \n  第一行  文字 \n第二行" })).toBe("第一行 文字");
		expect(deriveTitle({ data: null, text: "\r\nHello\r\nWorld" })).toBe("Hello");
		expect(deriveTitle({ data: ["title"], text: "Array data" })).toBe("Array data");
	});

	it("returns 未命名 when nothing is usable", () => {
		expect(deriveTitle({ data: null, text: null })).toBe("未命名");
		expect(deriveTitle({ data: {}, text: " \n " })).toBe("未命名");
	});
});

describe("sanitizeFileName", () => {
	it("strips forbidden characters", () => {
		expect(sanitizeFileName('a\\b/c:d*e?f"g<h>i|j#k^l[m]n')).toBe("abcdefghijklmn");
	});

	it("collapses whitespace and control characters", () => {
		expect(sanitizeFileName("  a \t b\n\nc\u0000d  ")).toBe("a b c d");
	});

	it("truncates to 60 characters without splitting surrogate pairs", () => {
		expect(sanitizeFileName("字".repeat(80))).toBe("字".repeat(60));
		const emoji = "😀".repeat(70);
		const result = sanitizeFileName(emoji);
		expect(Array.from(result)).toHaveLength(60);
		expect(result).toBe("😀".repeat(60));
	});

	it("trims spaces left by truncation and removes leading/trailing dots", () => {
		expect(sanitizeFileName(`${"a".repeat(59)} b`)).toBe("a".repeat(59));
		expect(sanitizeFileName("...hidden.")).toBe("hidden");
	});

	it("avoids Windows reserved names", () => {
		expect(sanitizeFileName("CON")).toBe("CON_");
	});

	it("can return an empty string", () => {
		expect(sanitizeFileName("[[##]]")).toBe("");
	});
});

describe("timestamps", () => {
	it("formats local time (Asia/Taipei in tests)", () => {
		expect(formatNoteTimestamp("2026-10-02T03:10:00.000Z")).toBe("2026-10-02 1110");
		expect(formatNoteTimestamp("2026-12-31T16:05:00.000Z")).toBe("2027-01-01 0005");
		expect(formatDateTime("2026-10-02T03:10:00.000Z")).toBe("2026-10-02 11:10");
		expect(formatClock(new Date("2026-10-02T01:02:00.000Z"))).toBe("09:02");
	});

	it("falls back to the second timestamp when the first is invalid", () => {
		expect(formatNoteTimestamp("not a date", "2026-10-02T03:10:00.000Z")).toBe("2026-10-02 1110");
		expect(formatNoteTimestamp(undefined, "2026-10-02T03:10:00.000Z")).toBe("2026-10-02 1110");
	});
});

describe("paths", () => {
	it("normalizes folders", () => {
		expect(normalizeFolder("/LocalOCR//掃描/ ")).toBe("LocalOCR/掃描");
		expect(normalizeFolder("a\\b")).toBe("a/b");
		expect(normalizeFolder("  ")).toBe("");
		expect(normalizeFolder("/")).toBe("");
	});

	it("resolves template names", () => {
		const map = new Map([["receipt", "收據／發票"]]);
		expect(resolveTemplateName("receipt", map)).toBe("收據／發票");
		expect(resolveTemplateName("unknown", map)).toBe("unknown");
		expect(resolveTemplateName(null, map)).toBeNull();
		expect(resolveTemplateName(undefined, map)).toBeNull();
	});

	it("builds the note path with a template subfolder", () => {
		const scan = exampleScan();
		expect(buildNotePath(scan, { folder: "LocalOCR", subfolderPerTemplate: true, templateName: "收據／發票" })).toBe(
			"LocalOCR/收據／發票/2026-10-02 1110 全聯福利中心.md",
		);
	});

	it("uses 未分類 when there is no template", () => {
		const scan = exampleScan({ templateId: null });
		expect(buildNotePath(scan, { folder: "LocalOCR", subfolderPerTemplate: true, templateName: null })).toBe(
			"LocalOCR/未分類/2026-10-02 1110 全聯福利中心.md",
		);
	});

	it("omits the subfolder when disabled and supports the vault root", () => {
		const scan = exampleScan();
		expect(buildNotePath(scan, { folder: "LocalOCR/", subfolderPerTemplate: false, templateName: "收據" })).toBe(
			"LocalOCR/2026-10-02 1110 全聯福利中心.md",
		);
		expect(buildNotePath(scan, { folder: "", subfolderPerTemplate: false, templateName: null })).toBe(
			"2026-10-02 1110 全聯福利中心.md",
		);
	});

	it("sanitizes template names and titles", () => {
		const scan = exampleScan({ data: { title: "A/B: #1 [draft]?" } });
		expect(buildNotePath(scan, { folder: "Scans", subfolderPerTemplate: true, templateName: "收據/發票" })).toBe(
			"Scans/收據發票/2026-10-02 1110 AB 1 draft.md",
		);
	});

	it("falls back to the text and then to 未命名 for the title", () => {
		const fromText = exampleScan({ data: { total: 1 }, text: "名片\n王小明" });
		expect(buildNotePath(fromText, { folder: "X", subfolderPerTemplate: false, templateName: null })).toBe(
			"X/2026-10-02 1110 名片.md",
		);
		const empty = exampleScan({ data: { title: "###" }, text: "" });
		expect(buildNotePath(empty, { folder: "X", subfolderPerTemplate: false, templateName: null })).toBe(
			"X/2026-10-02 1110 未命名.md",
		);
	});

	it("appends numeric suffixes on collisions", async () => {
		expect(withNumberSuffix("a/b/name.md", 2)).toBe("a/b/name (2).md");
		expect(withNumberSuffix("noext", 3)).toBe("noext (3)");
		const taken = new Set(["F/n.md", "F/n (2).md"]);
		expect(await uniquePath("F/n.md", (p) => taken.has(p))).toBe("F/n (3).md");
		expect(await uniquePath("F/free.md", async (p) => taken.has(p))).toBe("F/free.md");
	});
});

describe("renderNote", () => {
	it("renders the documented example", () => {
		expect(renderNote(exampleScan(), RECEIPT_OPTS)).toBe(
			[
				"---",
				'localocr_id: "6F1C9D0E-2B7A-4E43-9A57-5B1E9F0C2D11"',
				'created: "2026-10-02T03:10:00.000Z"',
				'updated: "2026-10-02T03:10:02.000Z"',
				"template: receipt",
				'template_name: "收據／發票"',
				"source: camera",
				"confidence: 0.93",
				"classifier: jev",
				"tags: [localocr, localocr/receipt]",
				"---",
				MARKER_START,
				"",
				"# 全聯福利中心",
				"",
				"## 結構化資料",
				"",
				"```json",
				"{",
				'  "store": "全聯福利中心",',
				'  "date": null,',
				'  "items": [',
				"    {",
				'      "name": "鮮乳",',
				'      "quantity": 1,',
				'      "price": 45',
				"    }",
				"  ],",
				'  "total": 45,',
				'  "currency": "TWD"',
				"}",
				"```",
				"",
				"## 辨識文字",
				"",
				"```text",
				"全聯福利中心",
				"鮮乳 45",
				"合計 45",
				"```",
				"",
				MARKER_END,
				"",
			].join("\n"),
		);
	});

	it("preserves data key order exactly as received", () => {
		const scan = exampleScan({ data: { z: 1, a: 2, m: { y: 1, b: 2 } } });
		expect(renderNote(scan, RECEIPT_OPTS)).toContain(JSON.stringify({ z: 1, a: 2, m: { y: 1, b: 2 } }, null, 2));
	});

	it("omits the OCR text when disabled or empty", () => {
		expect(renderNote(exampleScan(), { ...RECEIPT_OPTS, includeText: false })).not.toContain("## 辨識文字");
		expect(renderNote(exampleScan({ text: "  \n" }), RECEIPT_OPTS)).not.toContain("## 辨識文字");
	});

	it("handles scans without template, classification or data", () => {
		const note = renderNote(
			exampleScan({ templateId: null, classification: null, data: null, source: undefined }),
			{ templateName: null, includeText: true },
		);
		expect(note).toContain("template: null\ntemplate_name: null\nsource: null\ntags: [localocr]\n---");
		expect(note).not.toContain("confidence:");
		expect(note).not.toContain("classifier:");
		expect(note).toContain("# 全聯福利中心");
		expect(note).toContain("_（無結構化資料）_");
	});

	it("quotes YAML values that need it", () => {
		expect(yamlScalar("receipt")).toBe("receipt");
		expect(yamlScalar("true")).toBe('"true"');
		expect(yamlScalar("a: b")).toBe('"a: b"');
		expect(yamlScalar('say "hi"\n')).toBe('"say \\"hi\\"\\n"');
		expect(yamlScalar(0.5)).toBe("0.5");
		expect(yamlScalar(Number.NaN)).toBe("null");
		expect(yamlScalar(null)).toBe("null");
	});

	it("escapes code fences inside the OCR text", () => {
		const text = "before\n```\nnot a fence\n````js\nafter ``` inline";
		expect(escapeFence(text)).not.toMatch(/```/);
		const block = renderBlock(exampleScan({ text }), true);
		const lines = block.split("\n");
		const fenceLines = lines.filter((line) => /^\s{0,3}```/.test(line));
		// Only the json open/close and text open/close fences remain.
		expect(fenceLines).toEqual(["```json", "```", "```text", "```"]);
		expect(block).toContain("not a fence");
	});

	it("never emits its own markers from scan content", () => {
		const block = renderBlock(exampleScan({ text: `x\n${MARKER_END}\ny`, data: { title: MARKER_START } }), true);
		expect(block.split(MARKER_START)).toHaveLength(2);
		expect(block.split(MARKER_END)).toHaveLength(2);
	});
});

describe("frontmatter parsing", () => {
	it("splits frontmatter and body", () => {
		expect(splitFrontmatter("---\na: 1\n---\nbody")).toEqual({ frontmatter: ["a: 1"], body: "body" });
		expect(splitFrontmatter("\uFEFF---\r\na: 1\r\n---\r\nbody\r\n")).toEqual({ frontmatter: ["a: 1"], body: "body\n" });
		expect(splitFrontmatter("no frontmatter")).toEqual({ frontmatter: null, body: "no frontmatter" });
		expect(splitFrontmatter("---\nunterminated")).toEqual({ frontmatter: null, body: "---\nunterminated" });
	});

	it("groups top-level keys with their continuation lines", () => {
		const blocks = parseFrontmatterBlocks(["# comment", "a: 1", "list:", "  - x", "- y", '"quoted key": 2', "url: http://x"]);
		expect(blocks.map((b) => b.key)).toEqual([null, "a", "list", "quoted key", "url"]);
		expect(blocks[2].lines).toEqual(["list:", "  - x", "- y"]);
	});

	it("parses tags in flow, block and scalar form", () => {
		expect(parseTagsBlock(["tags: [localocr, 'my tag', \"#x\"]"])).toEqual(["localocr", "my tag", "x"]);
		expect(parseTagsBlock(["tags:", "  - a", "  - b # note", "- c"])).toEqual(["a", "b", "c"]);
		expect(parseTagsBlock(["tags: one, two"])).toEqual(["one", "two"]);
		expect(parseTagsBlock(["tags: [a,", "  b]"])).toEqual(["a", "b"]);
	});
});

describe("mergeNote", () => {
	it("is idempotent for an untouched note", () => {
		const note = renderNote(exampleScan(), RECEIPT_OPTS);
		expect(mergeNote(note, exampleScan(), RECEIPT_OPTS)).toBe(note);
	});

	it("replaces generated content and keeps user content outside the markers", () => {
		const original = renderNote(exampleScan(), RECEIPT_OPTS);
		const edited = original
			.replace(MARKER_START, `使用者在上面寫的筆記\n\n${MARKER_START}`)
			.replace("合計 45", "（使用者在區塊內的修改會被覆寫）")
			.concat("\n## 我的筆記\n\n- 記得報帳 [[2026 支出]]\n");
		const updatedScan = exampleScan({
			updatedAt: "2026-10-03T00:00:00.000Z",
			data: { store: "全聯", total: 99 },
			text: "全聯\n合計 99",
		});
		const merged = mergeNote(edited, updatedScan, RECEIPT_OPTS);

		expect(merged).toContain("使用者在上面寫的筆記\n\n" + MARKER_START);
		expect(merged).toContain("\n## 我的筆記\n\n- 記得報帳 [[2026 支出]]\n");
		expect(merged).toContain('updated: "2026-10-03T00:00:00.000Z"');
		expect(merged).toContain("# 全聯\n");
		expect(merged).toContain('"total": 99');
		expect(merged).not.toContain("使用者在區塊內的修改會被覆寫");
		expect(merged).not.toContain("全聯福利中心");
		// The block itself equals a freshly rendered one.
		expect(merged).toContain(renderBlock(updatedScan, true));
	});

	it("keeps user frontmatter keys and extra tags", () => {
		const existing = [
			"---",
			'localocr_id: "old"',
			"created: x",
			"confidence: 0.5",
			"status: 待處理",
			"aliases:",
			"  - 收據 A",
			"tags:",
			"  - localocr",
			"  - localocr/document",
			"  - 報帳",
			"  - 2026/十月",
			"---",
			MARKER_START,
			"old",
			MARKER_END,
			"",
			"user text",
			"",
		].join("\n");
		const merged = mergeNote(existing, exampleScan({ classification: null }), RECEIPT_OPTS);
		const { frontmatter, body } = splitFrontmatter(merged);
		expect(frontmatter).toEqual([
			'localocr_id: "6F1C9D0E-2B7A-4E43-9A57-5B1E9F0C2D11"',
			'created: "2026-10-02T03:10:00.000Z"',
			'updated: "2026-10-02T03:10:02.000Z"',
			"template: receipt",
			'template_name: "收據／發票"',
			"source: camera",
			"tags: [localocr, localocr/receipt, 報帳, 2026/十月]",
			"status: 待處理",
			"aliases:",
			"  - 收據 A",
		]);
		expect(body).toBe(`${renderBlock(exampleScan(), true)}\n\nuser text\n`);
		// Merging again changes nothing.
		expect(mergeNote(merged, exampleScan({ classification: null }), RECEIPT_OPTS)).toBe(merged);
	});

	it("re-inserts the block at the top when the markers were removed", () => {
		const existing = "---\nlocalocr_id: x\nmine: 1\n---\n\n\n我刪掉了產生的內容，只留下自己的筆記。\n";
		const merged = mergeNote(existing, exampleScan(), RECEIPT_OPTS);
		expect(merged.endsWith(`${MARKER_END}\n\n我刪掉了產生的內容，只留下自己的筆記。\n`)).toBe(true);
		expect(merged).toContain("mine: 1\n---\n" + MARKER_START);
	});

	it("adds frontmatter to a note without one and handles CRLF", () => {
		const existing = `${MARKER_START}\r\nold\r\n${MARKER_END}\r\nafter\r\n`;
		const merged = mergeNote(existing, exampleScan(), RECEIPT_OPTS);
		expect(merged.startsWith('---\nlocalocr_id: "6F1C9D0E')).toBe(true);
		expect(merged.endsWith(`${MARKER_END}\nafter\n`)).toBe(true);
		expect(merged).not.toContain("\r");
	});

	it("drops the OCR text section when includeText is turned off", () => {
		const note = renderNote(exampleScan(), RECEIPT_OPTS);
		const merged = mergeNote(note, exampleScan(), { ...RECEIPT_OPTS, includeText: false });
		expect(merged).not.toContain("## 辨識文字");
		expect(merged).toBe(renderNote(exampleScan(), { ...RECEIPT_OPTS, includeText: false }));
	});
});
