// Obsidian note parsing for GET /v1/vault/index (and the assistant's link tools). The rules mirror the iOS app's
// own parser, so the graph, backlinks, tags and tasks look the same whether a note was downloaded or not.

/** Bump when the parsed output changes: it is part of the index ETag, so clients refetch. */
export const PARSER_VERSION = 2;

export const MAX_TASKS = 200;
export const SNIPPET_MAX_CHARS = 160;

/** Link targets with these extensions are attachments, not notes (left out of `links`). */
export const ATTACHMENT_EXTENSIONS: ReadonlySet<string> = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "pdf",
  "mp3", "m4a", "wav", "ogg", "mp4", "mov", "webm", "canvas", "ink",
]);

/** The app's wikilink pattern: group 1 = "!" for embeds, group 2 = the target before any |, # or ^. */
export const WIKILINK_PATTERN = /(!?)\[\[([^\]\|#\^]+)[^\]]*\]\]/g;
const TASK_PATTERN = /^\s*[-*+] \[( |x|X)\] (.*)$/;
const EMBED_WIKILINK = /!\[\[([^\]]*)\]\]/;
const EMBED_MARKDOWN = /!\[[^\]]*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/;
const URL_SCHEME = /^[a-z][a-z0-9+.-]*:/i;

export type FrontmatterValue = string | string[] | null;

export interface Frontmatter {
  data: Record<string, FrontmatterValue>;
  /** The text after the frontmatter block (the whole text when there is none). */
  body: string;
}

export interface NoteTask {
  text: string;
  done: boolean;
}

/** The parsed fields of one note, as they appear in the index response. */
export interface ParsedNote {
  title: string;
  aliases: string[];
  tags: string[];
  links: string[];
  firstEmbed: string | null;
  tasks: NoteTask[];
  snippet: string;
  notebook: string | null;
  /** The frontmatter as simple YAML (Dataview's page fields): string, list of strings, or null for empty/nested. */
  properties: Record<string, FrontmatterValue>;
}

/** ParsedNote plus every wikilink target (attachments included), for link resolution and retargeting. */
export interface ParsedNoteDetail extends ParsedNote {
  allLinks: string[];
}

const basename = (path: string) => path.slice(path.lastIndexOf("/") + 1);

/** File name without a trailing ".md" (any case). */
export function noteTitle(path: string): string {
  return basename(path).replace(/\.md$/i, "");
}

/** Lowercased extension of the last path segment ("" when none). */
export function linkExtension(target: string): string {
  const name = basename(target);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

function unquote(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length >= 2) {
    const first = trimmed[0];
    if ((first === '"' || first === "'") && trimmed.endsWith(first)) return trimmed.slice(1, -1).trim();
  }
  return trimmed;
}

/** "value  # comment" → "value" (only an unquoted " #" starts a YAML comment). */
function stripComment(value: string): string {
  const trimmed = value.trim();
  if (trimmed.startsWith('"') || trimmed.startsWith("'")) return trimmed;
  const hash = trimmed.search(/\s#/);
  return hash >= 0 ? trimmed.slice(0, hash).trim() : trimmed;
}

function splitInline(value: string): string[] {
  return value
    .split(",")
    .map(unquote)
    .filter((item) => item !== "");
}

/**
 * The leading `---` … `---` block as simple YAML: `key: value`, inline arrays `[a, b]` and `- item` lists.
 * Nested structures are not parsed (their keys keep a null value).
 */
export function parseFrontmatter(text: string): Frontmatter {
  const source = text.replace(/^﻿/, "");
  const match = /^---[ \t]*\r?\n(?:([\s\S]*?)\r?\n)?---[ \t]*(?:\r?\n|$)/.exec(source);
  if (!match) return { data: {}, body: source };
  const data: Record<string, FrontmatterValue> = {};
  let listKey: string | null = null;
  for (const rawLine of (match[1] ?? "").split(/\r?\n/)) {
    if (rawLine.trim() === "" || rawLine.trimStart().startsWith("#")) continue;
    const item = /^\s*-\s+(.*)$/.exec(rawLine) ?? /^\s*-$/.exec(rawLine);
    if (item && listKey !== null) {
      const value = unquote(stripComment(item[1] ?? ""));
      const current = data[listKey];
      const list = Array.isArray(current) ? current : [];
      if (value !== "") list.push(value);
      data[listKey] = list;
      continue;
    }
    const pair = /^([^\s:#][^:]*?)\s*:(?:\s+(.*)|\s*)$/.exec(rawLine);
    if (!pair || /^\s/.test(rawLine)) {
      if (!/^\s/.test(rawLine)) listKey = null;
      continue;
    }
    const key = unquote(pair[1]!);
    const raw = stripComment(pair[2] ?? "");
    if (raw === "") {
      data[key] = null;
      listKey = key;
    } else if (raw.startsWith("[") && raw.endsWith("]")) {
      data[key] = splitInline(raw.slice(1, -1));
      listKey = null;
    } else {
      data[key] = unquote(raw);
      listKey = null;
    }
  }
  return { data, body: source.slice(match[0].length) };
}

/** A frontmatter value as a list: YAML list, inline array or "a, b". */
function listValue(value: FrontmatterValue | undefined): string[] {
  if (value === undefined || value === null) return [];
  if (Array.isArray(value)) return value.map(unquote).filter((item) => item !== "");
  return splitInline(value);
}

function dedupe(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const key = value.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(value);
  }
  return result;
}

/** Every wikilink target (trimmed, deduplicated case-insensitively, first spelling kept), attachments included. */
export function extractAllLinks(text: string): string[] {
  const targets: string[] = [];
  for (const match of text.matchAll(WIKILINK_PATTERN)) {
    const target = match[2]!.trim();
    if (target) targets.push(target);
  }
  return dedupe(targets);
}

/** Note links like the app: wikilink targets whose extension is not an attachment's. */
export function extractLinks(text: string): string[] {
  return extractAllLinks(text).filter((target) => !ATTACHMENT_EXTENSIONS.has(linkExtension(target)));
}

function decodeTarget(raw: string): string {
  const target = raw.startsWith("<") && raw.endsWith(">") ? raw.slice(1, -1) : raw;
  try {
    return decodeURIComponent(target).trim();
  } catch {
    return target.trim();
  }
}

/** The first `![[x]]` target (without `|size`) or local `![](x)` target, whichever comes first. */
export function extractFirstEmbed(text: string): string | null {
  const candidates: { index: number; target: string }[] = [];
  let offset = 0;
  // the first wikilink embed with a non-empty target
  for (;;) {
    const wiki = EMBED_WIKILINK.exec(text.slice(offset));
    if (!wiki) break;
    const target = wiki[1]!.split("|")[0]!.trim();
    if (target) {
      candidates.push({ index: offset + wiki.index, target });
      break;
    }
    offset += wiki.index + wiki[0].length;
  }
  offset = 0;
  // the first markdown image with a local (scheme-less) target
  for (;;) {
    const markdown = EMBED_MARKDOWN.exec(text.slice(offset));
    if (!markdown) break;
    const target = decodeTarget(markdown[1]!);
    if (target && !URL_SCHEME.test(target) && !target.startsWith("//")) {
      candidates.push({ index: offset + markdown.index, target });
      break;
    }
    offset += markdown.index + markdown[0].length;
  }
  candidates.sort((a, b) => a.index - b.index);
  return candidates[0]?.target ?? null;
}

export function extractTasks(text: string, max = MAX_TASKS): NoteTask[] {
  const tasks: NoteTask[] = [];
  for (const line of text.split("\n")) {
    if (tasks.length >= max) break;
    const match = TASK_PATTERN.exec(line.replace(/\r$/, ""));
    if (match) tasks.push({ text: match[2]!, done: match[1] !== " " });
  }
  return tasks;
}

const FENCE = /^\s{0,3}(```|~~~)/;
const HEADING = /^\s{0,3}#{1,6}(\s|$)/;
const THEMATIC_BREAK = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/;
const LIST_ITEM = /^\s*(?:[-*+]|\d+[.)])\s+(.*)$/;
const EMBEDS_ONLY = /^\s*(?:(?:!\[\[[^\]]*\]\]|!\[[^\]]*\]\([^)]*\))\s*)+$/;

function truncateChars(text: string, max: number): string {
  const chars = Array.from(text);
  return chars.length <= max ? text : chars.slice(0, max).join("");
}

/**
 * The first paragraph or list item of the body (frontmatter already removed), skipping headings, code fences,
 * blank lines and lines that only hold embeds; whitespace collapsed, at most 160 characters.
 */
export function extractSnippet(body: string, max = SNIPPET_MAX_CHARS): string {
  const lines = body.split("\n").map((line) => line.replace(/\r$/, ""));
  let inFence = false;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    if (FENCE.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence || line.trim() === "" || HEADING.test(line) || THEMATIC_BREAK.test(line) || EMBEDS_ONLY.test(line)) {
      continue;
    }
    const item = LIST_ITEM.exec(line);
    let text: string;
    if (item) {
      text = item[1]!.replace(/^\[[ xX]\]\s+/, "");
    } else {
      const paragraph = [line];
      for (let next = index + 1; next < lines.length; next += 1) {
        const following = lines[next]!;
        if (following.trim() === "" || FENCE.test(following) || HEADING.test(following) || LIST_ITEM.test(following)) break;
        paragraph.push(following);
      }
      text = paragraph.join("\n");
    }
    const collapsed = text.replace(/\s+/g, " ").trim();
    if (collapsed) return truncateChars(collapsed, max);
  }
  return "";
}

/** Parses a note's text into the index fields (plus every link target for resolution). */
export function parseNote(path: string, text: string): ParsedNoteDetail {
  const { data, body } = parseFrontmatter(text);
  const source = text.replace(/^﻿/, "");
  const notebook = data["localocr-notebook"];
  const allLinks = extractAllLinks(source);
  return {
    title: noteTitle(path),
    aliases: dedupe([...listValue(data.aliases), ...listValue(data.alias)]),
    tags: dedupe([...listValue(data.tags), ...listValue(data.tag)].map((tag) => tag.replace(/^#+/, "").trim()).filter(Boolean)),
    links: allLinks.filter((target) => !ATTACHMENT_EXTENSIONS.has(linkExtension(target))),
    firstEmbed: extractFirstEmbed(source),
    tasks: extractTasks(body),
    snippet: extractSnippet(body),
    notebook: typeof notebook === "string" && notebook !== "" ? notebook : null,
    properties: data,
    allLinks,
  };
}
