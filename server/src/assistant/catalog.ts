import type Anthropic from "@anthropic-ai/sdk";

// Which Claude model cloud runs use. With ASSISTANT_MODEL=latest (the default) the server follows new releases on
// its own: models.dev (an open-source, community-maintained catalog of AI models, github.com/sst/models.dev) says
// which models exist, their family, release date and tool support; Anthropic's Models API says which of them this
// API key can actually call. A newer model appears in the catalog or the Models API → the next refresh picks it up.

/** models.dev's full catalog (all providers; we read Anthropic's models). */
export const MODELS_DEV_URL = "https://models.dev/api.json";
/** Used until the first refresh finishes, and whenever nothing can be resolved. */
export const DEFAULT_ASSISTANT_MODEL = "claude-opus-5-5";
/** The same for each family. */
export const DEFAULT_FAMILY_MODELS: Record<string, string> = {
  "claude-opus": DEFAULT_ASSISTANT_MODEL,
  "claude-sonnet": "claude-sonnet-5-5",
  "claude-haiku": "claude-haiku-5-5",
  "claude-fable": "claude-fable-5-1",
};
const REFRESH_INTERVAL_MS = 6 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 15_000;

/** One Anthropic model from models.dev. */
export interface CatalogEntry {
  id: string;
  /** e.g. "claude-opus" */
  family?: string;
  /** Another id the same model is served under (models.dev's canonical_model_id). */
  canonicalId?: string;
  /** YYYY-MM-DD */
  releaseDate?: string;
  toolCall?: boolean;
  experimental?: boolean;
}

/** A model this API key can call (Anthropic Models API). */
export interface AvailableModel {
  id: string;
  /** RFC 3339 */
  createdAt: string;
}

/** ASSISTANT_MODEL: "latest" = newest Opus; "latest-sonnet", "latest-haiku", "latest-fable", "latest-opus" = newest of that family; anything else is a fixed model id. */
export function parseModelSetting(value: string): { fixed: string } | { family: string } {
  const trimmed = value.trim();
  const normalized = trimmed.toLowerCase();
  if (normalized === "latest") return { family: "claude-opus" };
  const match = /^latest[-:](?:claude-)?([a-z0-9]+)$/.exec(normalized);
  if (match) return { family: `claude-${match[1]}` };
  return { fixed: trimmed };
}

/** Anthropic's models from models.dev's api.json (unknown fields ignored, malformed entries skipped). */
export function parseModelsDev(json: unknown): CatalogEntry[] {
  if (!json || typeof json !== "object") return [];
  const provider = (json as Record<string, unknown>).anthropic;
  if (!provider || typeof provider !== "object") return [];
  const models = (provider as Record<string, unknown>).models;
  if (!models || typeof models !== "object") return [];
  return Object.values(models as Record<string, unknown>).flatMap((raw): CatalogEntry[] => {
    if (!raw || typeof raw !== "object") return [];
    const model = raw as Record<string, unknown>;
    if (typeof model.id !== "string" || model.id.length === 0) return [];
    return [
      {
        id: model.id,
        family: typeof model.family === "string" ? model.family : undefined,
        canonicalId: typeof model.canonical_model_id === "string" ? model.canonical_model_id : undefined,
        releaseDate: typeof model.release_date === "string" ? model.release_date : undefined,
        toolCall: typeof model.tool_call === "boolean" ? model.tool_call : undefined,
        experimental: model.experimental === true,
      },
    ];
  });
}

/**
 * The newest model of `family`. `catalog` may be empty (models.dev unreachable); `available` is null when the
 * Models API could not be asked. When both are known, only models the key can call count, and a model the API
 * already serves but models.dev doesn't list yet still counts (dated by the API's creation time).
 */
export function pickLatest(family: string, catalog: CatalogEntry[], available: AvailableModel[] | null): string | null {
  const inFamily = (id: string, entryFamily?: string) => (entryFamily ? entryFamily === family : id.startsWith(`${family}-`));
  const usable = available ? new Set(available.map((model) => model.id)) : null;
  const candidates: { id: string; date: string }[] = [];
  const listed = new Set<string>();
  for (const entry of catalog) {
    if (!inFamily(entry.id, entry.family)) continue;
    // listed even when skipped, so an experimental or tool-less model doesn't come back in through the Models API
    listed.add(entry.id);
    if (entry.canonicalId) listed.add(entry.canonicalId);
    if (entry.toolCall === false || entry.experimental) continue;
    if (usable && !usable.has(entry.id)) {
      if (entry.canonicalId && usable.has(entry.canonicalId)) candidates.push({ id: entry.canonicalId, date: entry.releaseDate ?? "" });
      continue;
    }
    candidates.push({ id: entry.id, date: entry.releaseDate ?? "" });
  }
  for (const model of available ?? []) {
    if (listed.has(model.id) || !inFamily(model.id)) continue;
    candidates.push({ id: model.id, date: model.createdAt.slice(0, 10) });
  }
  candidates.sort((a, b) => b.date.localeCompare(a.date) || b.id.localeCompare(a.id));
  return candidates[0]?.id ?? null;
}

export async function fetchModelsDev(fetchImpl: typeof fetch = fetch): Promise<CatalogEntry[]> {
  const response = await fetchImpl(MODELS_DEV_URL, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
  if (!response.ok) throw new Error(`models.dev answered HTTP ${response.status}`);
  return parseModelsDev(await response.json());
}

export async function listAnthropicModels(client: Anthropic): Promise<AvailableModel[]> {
  const models: AvailableModel[] = [];
  for await (const model of client.models.list({ limit: 100 }, { timeout: FETCH_TIMEOUT_MS })) {
    models.push({ id: model.id, createdAt: model.created_at });
  }
  return models;
}

/**
 * Share one fetch between callers for `ttlMs` (three tiers refresh together; the catalog is several MB).
 * A failed fetch is not cached.
 */
export function shared<T>(load: () => Promise<T>, ttlMs = 10 * 60 * 1000, now: () => number = Date.now): () => Promise<T> {
  let cached: { at: number; value: Promise<T> } | null = null;
  return () => {
    if (cached && now() - cached.at < ttlMs) return cached.value;
    const value = load();
    const entry = { at: now(), value };
    cached = entry;
    value.catch(() => {
      if (cached === entry) cached = null;
    });
    return value;
  };
}

function describe(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 200);
}

/** The model cloud runs use right now: fixed, or the newest of a family, refreshed every few hours. */
export class LatestModel {
  private current: string;
  private readonly family: string | null;
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(
    setting: string,
    private readonly sources: {
      fetchCatalog?: () => Promise<CatalogEntry[]>;
      listAvailable?: (() => Promise<AvailableModel[]>) | null;
      fallback?: string;
      logger?: Pick<Console, "info" | "warn">;
    } = {},
  ) {
    const parsed = parseModelSetting(setting);
    this.family = "family" in parsed ? parsed.family : null;
    this.current = "fixed" in parsed ? parsed.fixed : (sources.fallback ?? DEFAULT_FAMILY_MODELS[parsed.family] ?? DEFAULT_ASSISTANT_MODEL);
  }

  /** The model id for a new run. */
  get id(): string {
    return this.current;
  }

  /** Whether this follows new releases (ASSISTANT_MODEL=latest…). */
  get followsLatest(): boolean {
    return this.family !== null;
  }

  /** Look up the newest model now; keeps the current one when nothing better can be resolved. */
  async refresh(): Promise<string> {
    if (!this.family) return this.current;
    const logger = this.sources.logger ?? console;
    const fetchCatalog = this.sources.fetchCatalog ?? (() => fetchModelsDev());
    const listAvailable = this.sources.listAvailable;
    const [catalog, available] = await Promise.all([
      fetchCatalog().catch((error: unknown) => {
        logger.warn(`[assistant] models.dev unavailable (${describe(error)}); using the Models API only`);
        return [] as CatalogEntry[];
      }),
      listAvailable
        ? listAvailable().catch((error: unknown) => {
            logger.warn(`[assistant] Models API unavailable (${describe(error)})`);
            return null;
          })
        : Promise.resolve(null),
    ]);
    const picked = pickLatest(this.family, catalog, available);
    if (picked && picked !== this.current) {
      logger.info(`[assistant] cloud runs now use ${picked} (newest ${this.family})`);
      this.current = picked;
    }
    return this.current;
  }

  /** Refresh now and then every few hours (the timer doesn't keep the process alive). */
  start(): void {
    if (!this.family || this.timer) return;
    void this.refresh();
    this.timer = setInterval(() => void this.refresh(), REFRESH_INTERVAL_MS);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}
