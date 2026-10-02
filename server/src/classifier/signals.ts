/**
 * Strong signals: template keywords prefixed with "!" — text that only appears on that scenario's
 * documents, such as a vendor's tax ID or company name. The iOS app applies the same rule.
 */
export function strongSignals(keywords: readonly string[]): string[] {
  return keywords.filter((keyword) => keyword.startsWith("!") && keyword.length > 1).map((keyword) => keyword.slice(1));
}

/** The only template whose strong signals appear in `text`, or null when none or several match. */
export function matchStrongSignal(
  text: string,
  templates: readonly { id: string; keywords: readonly string[] }[],
): { templateId: string; signals: string[] } | null {
  const haystack = text.toLocaleLowerCase();
  const matches = templates.flatMap((template) => {
    const signals = strongSignals(template.keywords).filter((signal) => haystack.includes(signal.toLocaleLowerCase()));
    return signals.length ? [{ templateId: template.id, signals }] : [];
  });
  return matches.length === 1 ? matches[0]! : null;
}
