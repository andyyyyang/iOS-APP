// Pure helpers for「配對 iPhone／iPad」and「設定 Remotely Save（同步 vault）」: the server calls over
// the injected REST client, response checks, countdown text and error messages.
// No "obsidian" imports — unit-tested.

import { ApiError, describeError, type LocalOcrClient } from "./sync-core";

export const REMOTELY_SAVE_PLUGIN_ID = "remotely-save";

type JsonClient = Pick<LocalOcrClient, "requestJson">;

/** POST /v1/pairing (see docs/API.md「配對」). */
export interface PairingCode {
	/** "XXXX-XXXX" */
	code: string;
	expiresAt: string;
	/** localocr://pair?server=…&code=…, shown as a QR code. */
	pairUrl: string;
}

/** GET /v1/vault/remotely-save?vault=… */
export interface RemotelySaveSetup {
	/** Partial Remotely Save settings, including the bucket keys. */
	settings: Record<string, unknown>;
	/** obsidian://remotely-save?func=settings&… for this vault. */
	uri: string;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	!!value && typeof value === "object" && !Array.isArray(value);

export function parsePairingCode(body: unknown): PairingCode {
	if (
		!isObject(body) ||
		typeof body.code !== "string" ||
		typeof body.pairUrl !== "string" ||
		typeof body.expiresAt !== "string" ||
		Number.isNaN(Date.parse(body.expiresAt))
	) {
		throw new ApiError("伺服器 /v1/pairing 回應格式不正確", 201, "bad_response");
	}
	return { code: body.code, expiresAt: body.expiresAt, pairUrl: body.pairUrl };
}

export function parseRemotelySaveSetup(body: unknown): RemotelySaveSetup {
	if (
		!isObject(body) ||
		!isObject(body.settings) ||
		typeof body.uri !== "string" ||
		!body.uri.startsWith("obsidian://remotely-save?")
	) {
		throw new ApiError("伺服器 /v1/vault/remotely-save 回應格式不正確", 200, "bad_response");
	}
	return { settings: body.settings, uri: body.uri };
}

/**
 * Creates a single-use pairing code that hands this plugin's API key to the LocalOCR app.
 * No notes folder: the app syncs the whole vault and notes can live in any folder.
 */
export async function createPairingCode(client: JsonClient, vaultName: string): Promise<PairingCode> {
	const body = await client.requestJson("/v1/pairing", { method: "POST", body: { vaultName } });
	return parsePairingCode(body);
}

/** Remotely Save settings and import URI for the vault named `vaultName`. */
export async function fetchRemotelySaveSetup(client: JsonClient, vaultName: string): Promise<RemotelySaveSetup> {
	const body = await client.requestJson(`/v1/vault/remotely-save?vault=${encodeURIComponent(vaultName)}`);
	return parseRemotelySaveSetup(body);
}

/** Milliseconds until `expiresAt` (never negative; 0 for an unparseable date). */
export function remainingMs(expiresAt: string, now: number): number {
	const end = Date.parse(expiresAt);
	return Number.isNaN(end) ? 0 : Math.max(0, end - now);
}

/** "9:59" (seconds rounded up, so it reaches "0:00" only when the code has expired). */
export function formatCountdown(ms: number): string {
	const total = Number.isFinite(ms) && ms > 0 ? Math.ceil(ms / 1000) : 0;
	const minutes = Math.floor(total / 60);
	const seconds = total % 60;
	return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

/** Traditional Chinese explanation for a failed pairing or Remotely Save request. Never includes keys. */
export function describeSetupError(error: unknown): string {
	if (error instanceof ApiError) {
		if (error.code === "vault_not_configured") {
			return "伺服器尚未設定 Obsidian 儲存桶（VAULT_S3_* 變數），請先完成伺服器設定（見 docs/OBSIDIAN-SYNC.md）。";
		}
		if (error.isAuthError) return `${error.message}\n請到 LocalOCR 設定確認 API 金鑰。`;
		if (error.status === 404) {
			return `${error.message}\n伺服器可能是舊版：請更新並重新部署 LocalOCR 伺服器。`;
		}
	}
	return describeError(error);
}

/** A handler registered with `registerObsidianProtocolHandler`, called with the decoded URI parameters. */
export type ProtocolHandler = (params: Record<string, string>) => unknown;

/**
 * The protocol handler another plugin registered for obsidian://`action`, read defensively from
 * Obsidian's private registry (`workspace.protocolHandlers`, or `workspace.protocolHandler.handlers`
 * in newer versions); null when it cannot be found.
 */
export function findProtocolHandler(app: unknown, action: string): ProtocolHandler | null {
	type Registry = { get?: unknown } | null | undefined;
	const workspace = (app as { workspace?: { protocolHandlers?: Registry; protocolHandler?: { handlers?: Registry } } } | null | undefined)
		?.workspace;
	for (const registry of [workspace?.protocolHandlers, workspace?.protocolHandler?.handlers]) {
		const get = registry?.get;
		if (typeof get !== "function") continue;
		const handler: unknown = get.call(registry, action);
		if (typeof handler === "function") return handler as ProtocolHandler;
	}
	return null;
}

/**
 * The parameters Remotely Save's own obsidian://remotely-save handler expects, taken from the setup URI.
 * Desktop Obsidian drops `vault` from a link it opens through the operating system (it only uses it to pick
 * the window), and Remotely Save rejects an import without it, so `window.open(uri)` cannot work there;
 * calling the handler directly with the current vault name works on every platform.
 */
export function remotelySaveImportParams(setup: RemotelySaveSetup, vaultName: string): Record<string, string> {
	const query = setup.uri.includes("?") ? setup.uri.slice(setup.uri.indexOf("?") + 1) : "";
	const params: Record<string, string> = {};
	for (const [key, value] of new URLSearchParams(query)) params[key] = value;
	return {
		func: "settings",
		version: "localocr",
		data: JSON.stringify(setup.settings),
		...params,
		action: REMOTELY_SAVE_PLUGIN_ID,
		vault: vaultName,
	};
}

/**
 * Whether the community plugin `id` is enabled, read defensively from Obsidian's private
 * `app.plugins.enabledPlugins`; null when that cannot be determined.
 */
export function isPluginEnabled(app: unknown, id: string): boolean | null {
	const enabled = (app as { plugins?: { enabledPlugins?: unknown } } | null | undefined)?.plugins?.enabledPlugins;
	const has = (enabled as { has?: unknown } | null | undefined)?.has;
	if (typeof has !== "function") return null;
	return Boolean(has.call(enabled, id));
}
