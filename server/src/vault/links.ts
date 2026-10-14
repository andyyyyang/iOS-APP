import { WIKILINK_PATTERN, noteTitle } from "./markdown.js";

// Obsidian-style wikilink resolution and retargeting, case-insensitive:
// 1. the vault path (notes without ".md"), 2. the file name (shortest path wins; a target with folders must match the
// end of the path), 3. a note's aliases. Used by vault_links, the assistant's get_links and move_file link updates.

export interface LinkTargetEntry {
  path: string;
  aliases?: readonly string[];
}

const isNote = (path: string) => /\.md$/i.test(path);
const fold = (value: string) => value.normalize("NFC").toLowerCase();
/** "Folder/Note.md" → "folder/note"; "img/a.png" → "img/a.png". */
const pathKey = (path: string) => fold(isNote(path) ? path.slice(0, -3) : path);
const shortestFirst = (a: string, b: string) => a.length - b.length || (a < b ? -1 : a > b ? 1 : 0);

export class LinkResolver {
  private readonly byPath = new Map<string, string>();
  private readonly byName = new Map<string, string[]>();
  private readonly byAlias = new Map<string, string[]>();

  constructor(entries: Iterable<LinkTargetEntry>) {
    const push = (map: Map<string, string[]>, key: string, path: string) => {
      const list = map.get(key);
      if (list) list.push(path);
      else map.set(key, [path]);
    };
    for (const { path, aliases = [] } of entries) {
      const key = pathKey(path);
      if (!this.byPath.has(key)) this.byPath.set(key, path);
      push(this.byName, key.slice(key.lastIndexOf("/") + 1), path);
      for (const alias of aliases) push(this.byAlias, fold(alias.trim()), path);
    }
    for (const list of [...this.byName.values(), ...this.byAlias.values()]) list.sort(shortestFirst);
  }

  /** The vault path a link target (the part before |, # or ^) points to, or null. */
  resolve(rawTarget: string): string | null {
    let target = fold(rawTarget.trim()).replace(/^\/+/, "");
    if (!target) return null;
    if (target.endsWith(".md")) target = target.slice(0, -3);
    const exact = this.byPath.get(target);
    if (exact) return exact;
    const name = target.slice(target.lastIndexOf("/") + 1);
    const byName = this.byName.get(name)?.find((path) => !target.includes("/") || pathKey(path).endsWith(`/${target}`));
    if (byName) return byName;
    return this.byAlias.get(fold(rawTarget.trim()))?.[0] ?? null;
  }
}

/** Calls `rewrite` with each wikilink target; a returned string replaces it, keeping "!", #heading, ^block and |alias. */
export function rewriteWikilinks(text: string, rewrite: (target: string) => string | null): { text: string; count: number } {
  let count = 0;
  const result = text.replace(WIKILINK_PATTERN, (match: string, bang: string, target: string) => {
    const replacement = rewrite(target.trim());
    if (replacement === null) return match;
    count += 1;
    const rest = match.slice(bang.length + 2 + target.length, -2);
    return `${bang}[[${replacement}${rest}]]`;
  });
  return { text: result, count };
}

/**
 * The new target for a link that pointed to `from` before it moved to `to`, or null when it needs no change
 * (it points elsewhere, or still resolves to the moved file, e.g. through an alias or an unchanged unique name).
 * Path-style links get the new path; name-style links keep the name style when the new name is still unique.
 */
export function retargetLink(
  target: string,
  { from, to, before, after }: { from: string; to: string; before: LinkResolver; after: LinkResolver },
): string | null {
  if (before.resolve(target) !== from || after.resolve(target) === to) return null;
  const note = isNote(to);
  const withMd = note && /\.md$/i.test(target);
  const format = (value: string) => (withMd ? `${value}.md` : value);
  if (!target.includes("/")) {
    const byName = format(note ? noteTitle(to) : to.slice(to.lastIndexOf("/") + 1));
    if (after.resolve(byName) === to) return byName;
  }
  return format(note ? to.slice(0, -3) : to);
}
