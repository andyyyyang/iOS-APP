// Pure note-formatting helpers: titles, file names, paths, rendering and
// marker-preserving merges. No "obsidian" imports — unit-tested with vitest.

import type { Scan } from "./types";

export const MARKER_START = "<!-- localocr:start -->";
export const MARKER_END = "<!-- localocr:end -->";
export const UNCATEGORIZED = "未分類";
export const UNTITLED = "未命名";
export const MAX_TITLE_LENGTH = 60;

/** Keys in `data` that are tried, in order, to name a note. */
export const TITLE_KEYS = ["title", "store", "name", "company"] as const;

/** Frontmatter keys owned by the plugin; everything else belongs to the user. */
export const MANAGED_KEYS = [
	"localocr_id",
	"created",
	"updated",
	"template",
	"template_name",
	"source",
	"confidence",
	"classifier",
	"tags",
] as const;

export interface RenderOptions {
	/** Display name of the scan's template, or null when it has none. */
	templateName: string | null;
	/** Include the OCR text section. */
	includeText: boolean;
}

export interface PathOptions {
	folder: string;
	subfolderPerTemplate: boolean;
	templateName: string | null;
}

// ---------------------------------------------------------------------------
// Titles and file names

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function collapseWhitespace(value: string): string {
	return value.replace(/\s+/g, " ").trim();
}

/**
 * Human-readable title: first non-empty of data.title / store / name / company,
 * otherwise the first non-empty line of the OCR text, otherwise "未命名".
 */
export function deriveTitle(scan: Pick<Scan, "data" | "text">): string {
	if (isPlainObject(scan.data)) {
		for (const key of TITLE_KEYS) {
			const value = scan.data[key];
			if (typeof value === "string" || typeof value === "number") {
				const title = collapseWhitespace(String(value));
				if (title) return title;
			}
		}
	}
	if (typeof scan.text === "string") {
		for (const line of scan.text.split(/\r?\n/)) {
			const title = collapseWhitespace(line);
			if (title) return title;
		}
	}
	return UNTITLED;
}

const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[0-9]|lpt[0-9])$/i;

/**
 * Make a string safe for use as a file or folder name: strips \/:*?"<>|#^[]
 * and control characters, collapses whitespace, drops leading dots and
 * trailing dots/spaces, and truncates to `max` characters.
 */
export function sanitizeFileName(value: string, max = MAX_TITLE_LENGTH): string {
	let name = value
		// eslint-disable-next-line no-control-regex
		.replace(/[\u0000-\u001f\u007f]/g, " ")
		.replace(/[\\/:*?"<>|#^[\]]/g, "");
	name = collapseWhitespace(name);
	// Truncate by code points so surrogate pairs (emoji, rare CJK) stay intact.
	const chars = Array.from(name);
	if (chars.length > max) name = chars.slice(0, max).join("");
	name = name.replace(/^[.\s]+/, "").replace(/[.\s]+$/, "");
	if (WINDOWS_RESERVED.test(name)) name = `${name}_`;
	return name;
}

function pad2(n: number): string {
	return n < 10 ? `0${n}` : String(n);
}

function parseDate(...candidates: Array<string | null | undefined>): Date {
	for (const candidate of candidates) {
		if (typeof candidate !== "string") continue;
		const date = new Date(candidate);
		if (!Number.isNaN(date.getTime())) return date;
	}
	return new Date();
}

/** `YYYY-MM-DD HHmm` in local time. Falls back to `fallback`, then now. */
export function formatNoteTimestamp(iso: string | null | undefined, fallback?: string | null): string {
	const d = parseDate(iso, fallback);
	return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}${pad2(d.getMinutes())}`;
}

/** `YYYY-MM-DD HH:mm` in local time, for tooltips and settings. */
export function formatDateTime(iso: string): string {
	const d = parseDate(iso);
	return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** `HH:mm` in local time, for the status bar. */
export function formatClock(date: Date): string {
	return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

// ---------------------------------------------------------------------------
// Paths

/** Normalise a vault folder: forward slashes, no leading/trailing or doubled slashes. */
export function normalizeFolder(folder: string): string {
	return folder
		.replace(/\\/g, "/")
		.split("/")
		.map((part) => part.trim())
		.filter((part) => part.length > 0 && part !== ".")
		.join("/");
}

export function joinPath(...parts: string[]): string {
	return parts.filter((part) => part.length > 0).join("/");
}

/** Template display name: the template's name, else its id, else null. */
export function resolveTemplateName(
	templateId: string | null | undefined,
	templates: ReadonlyMap<string, string>,
): string | null {
	if (!templateId) return null;
	const name = templates.get(templateId);
	return name && name.trim() ? name.trim() : templateId;
}

/**
 * `<folder>/<template name | 未分類>/<YYYY-MM-DD HHmm> <title>.md`
 * (the template segment only when `subfolderPerTemplate` is on).
 */
export function buildNotePath(scan: Pick<Scan, "createdAt" | "updatedAt" | "data" | "text">, opts: PathOptions): string {
	const folder = normalizeFolder(opts.folder);
	const sub = opts.subfolderPerTemplate
		? sanitizeFileName(opts.templateName ?? "") || UNCATEGORIZED
		: "";
	const title = sanitizeFileName(deriveTitle(scan)) || UNTITLED;
	const file = `${formatNoteTimestamp(scan.createdAt, scan.updatedAt)} ${title}.md`;
	return joinPath(folder, sub, file);
}

/** `a/b/name.md` + 2 → `a/b/name (2).md` */
export function withNumberSuffix(path: string, n: number): string {
	const extIndex = /\.md$/i.test(path) ? path.length - 3 : path.length;
	return `${path.slice(0, extIndex)} (${n})${path.slice(extIndex)}`;
}

/** First of `path`, `path (2)`, `path (3)`, … for which `exists` is false. */
export async function uniquePath(
	path: string,
	exists: (candidate: string) => boolean | Promise<boolean>,
	maxAttempts = 1000,
): Promise<string> {
	if (!(await exists(path))) return path;
	for (let n = 2; n <= maxAttempts; n++) {
		const candidate = withNumberSuffix(path, n);
		if (!(await exists(candidate))) return candidate;
	}
	throw new Error(`找不到可用的檔名：${path}`);
}

// ---------------------------------------------------------------------------
// Rendering

const YAML_PLAIN = /^[A-Za-z][A-Za-z0-9_-]*$/;
const YAML_RESERVED = /^(true|false|yes|no|on|off|y|n|null|nan|inf)$/i;

/** Serialise a scalar for YAML frontmatter (JSON strings are valid YAML). */
export function yamlScalar(value: unknown): string {
	if (value === null || value === undefined) return "null";
	if (typeof value === "number") return Number.isFinite(value) ? String(value) : "null";
	if (typeof value === "boolean") return String(value);
	const str = String(value);
	if (YAML_PLAIN.test(str) && !YAML_RESERVED.test(str)) return str;
	return JSON.stringify(str);
}

function yamlFlowItem(tag: string): string {
	return /^[\p{L}\p{N}_\-/]+$/u.test(tag) && !YAML_RESERVED.test(tag) ? tag : JSON.stringify(tag);
}

export function scanTags(scan: Pick<Scan, "templateId">): string[] {
	return scan.templateId ? ["localocr", `localocr/${scan.templateId}`] : ["localocr"];
}

/** Lines (without `---` fences) of the plugin-managed frontmatter. */
export function renderFrontmatterLines(scan: Scan, templateName: string | null, extraTags: string[] = []): string[] {
	const lines = [
		`localocr_id: ${JSON.stringify(String(scan.id))}`,
		`created: ${yamlScalar(scan.createdAt)}`,
		`updated: ${yamlScalar(scan.updatedAt)}`,
		`template: ${yamlScalar(scan.templateId ?? null)}`,
		`template_name: ${yamlScalar(templateName)}`,
		`source: ${yamlScalar(scan.source ?? null)}`,
	];
	const confidence = scan.classification?.confidence;
	if (typeof confidence === "number" && Number.isFinite(confidence)) {
		lines.push(`confidence: ${yamlScalar(confidence)}`);
	}
	const provider = scan.classification?.provider;
	if (typeof provider === "string" && provider) {
		lines.push(`classifier: ${yamlScalar(provider)}`);
	}
	const tags: string[] = [];
	for (const tag of [...scanTags(scan), ...extraTags]) {
		if (!tags.includes(tag)) tags.push(tag);
	}
	lines.push(`tags: [${tags.map(yamlFlowItem).join(", ")}]`);
	return lines;
}

/** Break up runs of 3+ backticks with zero-width spaces so they cannot close a fence. */
export function escapeFence(text: string): string {
	return text.replace(/`{3,}/g, (run) => run.split("").join("\u200B"));
}

/** Prevent generated content from containing our own markers. */
export function neutralizeMarkers(text: string): string {
	return text
		.split(MARKER_START)
		.join("<!-- localocr\u200B:start -->")
		.split(MARKER_END)
		.join("<!-- localocr\u200B:end -->");
}

/** The generated block, including the start/end markers. */
export function renderBlock(scan: Scan, includeText: boolean): string {
	const lines: string[] = [`# ${deriveTitle(scan)}`, "", "## 結構化資料", ""];
	if (scan.data === null || scan.data === undefined) {
		lines.push("_（無結構化資料）_");
	} else {
		lines.push("```json", JSON.stringify(scan.data, null, 2), "```");
	}
	const text = typeof scan.text === "string" ? scan.text.replace(/\r\n?/g, "\n").replace(/\s+$/, "") : "";
	if (includeText && text.trim()) {
		lines.push("", "## 辨識文字", "", "```text", escapeFence(text), "```");
	}
	return [MARKER_START, "", neutralizeMarkers(lines.join("\n")), "", MARKER_END].join("\n");
}

function assemble(frontmatterLines: string[], body: string): string {
	return `---\n${frontmatterLines.join("\n")}\n---\n${body}`;
}

/** Full content of a brand-new note. */
export function renderNote(scan: Scan, opts: RenderOptions): string {
	return assemble(renderFrontmatterLines(scan, opts.templateName), `${renderBlock(scan, opts.includeText)}\n`);
}

// ---------------------------------------------------------------------------
// Merging into an existing note

export interface SplitNote {
	/** Frontmatter lines without the `---` fences, or null when absent. */
	frontmatter: string[] | null;
	body: string;
}

export function splitFrontmatter(text: string): SplitNote {
	const normalized = text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
	if (!normalized.startsWith("---\n")) return { frontmatter: null, body: normalized };
	const lines = normalized.split("\n");
	for (let i = 1; i < lines.length; i++) {
		const line = lines[i].trimEnd();
		if (line === "---" || line === "...") {
			return { frontmatter: lines.slice(1, i), body: lines.slice(i + 1).join("\n") };
		}
	}
	return { frontmatter: null, body: normalized };
}

interface FrontmatterBlock {
	key: string | null;
	lines: string[];
}

const TOP_LEVEL_KEY = /^("(?:[^"\\]|\\.)*"|'[^']*'|[^\s#\-'"][^:]*?)\s*:(?:\s|$)/;

function unquote(value: string): string {
	const v = value.trim();
	if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
		if (v.startsWith('"')) {
			try {
				return JSON.parse(v) as string;
			} catch {
				return v.slice(1, -1);
			}
		}
		return v.slice(1, -1).replace(/''/g, "'");
	}
	return v;
}

/** Group frontmatter lines into top-level `key:` blocks (continuations included). */
export function parseFrontmatterBlocks(lines: string[]): FrontmatterBlock[] {
	const blocks: FrontmatterBlock[] = [];
	for (const line of lines) {
		const match = TOP_LEVEL_KEY.exec(line);
		if (match) {
			blocks.push({ key: unquote(match[1]), lines: [line] });
		} else if (blocks.length > 0) {
			blocks[blocks.length - 1].lines.push(line);
		} else {
			blocks.push({ key: null, lines: [line] });
		}
	}
	return blocks;
}

/** Parse the tags of a `tags:` block (flow list, block list or scalar). */
export function parseTagsBlock(lines: string[]): string[] {
	const first = lines[0] ?? "";
	const rest = first.slice(first.indexOf(":") + 1).trim();
	let raw: string[] = [];
	if (rest.startsWith("[")) {
		const joined = [rest, ...lines.slice(1).map((l) => l.trim())].join(" ");
		const inner = joined.slice(1, joined.lastIndexOf("]") > 0 ? joined.lastIndexOf("]") : undefined);
		raw = inner.split(",");
	} else if (rest === "" || rest.startsWith("#")) {
		for (const line of lines.slice(1)) {
			const m = /^\s*-\s+(.*)$/.exec(line) ?? /^\s*-$/.exec(line);
			if (m && m[1] !== undefined) raw.push(m[1].replace(/\s+#.*$/, ""));
		}
	} else {
		raw = rest.split(",");
	}
	return raw
		.map((tag) => unquote(tag).replace(/^#/, "").trim())
		.filter((tag) => tag.length > 0);
}

function isOwnTag(tag: string): boolean {
	return tag === "localocr" || tag.startsWith("localocr/");
}

/**
 * Update an existing note: replace the plugin-managed frontmatter keys and the
 * content between the markers; keep the user's other frontmatter keys, their
 * extra tags and everything outside the markers. If the markers are missing,
 * the generated block is inserted at the top of the body.
 */
export function mergeNote(existing: string, scan: Scan, opts: RenderOptions): string {
	const { frontmatter, body } = splitFrontmatter(existing);
	const managed = new Set<string>(MANAGED_KEYS);
	const userBlocks: string[] = [];
	const extraTags: string[] = [];
	if (frontmatter) {
		for (const block of parseFrontmatterBlocks(frontmatter)) {
			if (block.key === "tags") {
				for (const tag of parseTagsBlock(block.lines)) {
					if (!isOwnTag(tag) && !extraTags.includes(tag)) extraTags.push(tag);
				}
			} else if (block.key === null || !managed.has(block.key)) {
				userBlocks.push(...block.lines);
			}
		}
	}
	const frontmatterLines = [...renderFrontmatterLines(scan, opts.templateName, extraTags), ...userBlocks];

	const block = renderBlock(scan, opts.includeText);
	const start = body.indexOf(MARKER_START);
	const end = start >= 0 ? body.indexOf(MARKER_END, start + MARKER_START.length) : -1;
	let newBody: string;
	if (start >= 0 && end >= 0) {
		newBody = body.slice(0, start) + block + body.slice(end + MARKER_END.length);
	} else {
		const rest = body.replace(/^\n+/, "");
		newBody = rest.trim() ? `${block}\n\n${rest}` : `${block}\n`;
	}
	return assemble(frontmatterLines, newBody);
}
