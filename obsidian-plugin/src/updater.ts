// Online updates: CI publishes every plugin version as the GitHub release "obsidian-plugin-<version>" with
// main.js and manifest.json (see .github/workflows/obsidian-plugin-release.yml). The user's LocalOCR server on
// Railway mirrors those releases into its storage bucket and serves <server>/obsidian-plugin/latest.json with each
// file's SHA-256 (server/src/services/obsidian-plugin.ts); the plugin reads that first and falls back to GitHub
// when no server is set or it has nothing to offer (404, 503, unreachable).
// This module finds the newest release, downloads and verifies its files; main.ts writes them into
// the plugin folder and reloads the plugin. No "obsidian" imports — unit-tested.

export const UPDATE_REPO = "andyyyyang/iOS-APP";
export const RELEASE_TAG_PREFIX = "obsidian-plugin-";
export const PLUGIN_ID = "localocr-sync";
/** On the LocalOCR server (no API key needed). */
export const SERVER_LATEST_PATH = "/obsidian-plugin/latest.json";
/** Automatic checks run at most this often (the GitHub fallback allows 60 unauthenticated API calls per hour). */
export const UPDATE_CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
/** An unanswered latest.json request counts as unreachable (then GitHub is asked). */
export const SERVER_TIMEOUT_MS = 15_000;
/** Files written in this order: the manifest (and with it the version) changes only once the code is in place. */
export const UPDATE_FILES = ["styles.css", "main.js", "manifest.json"] as const;
export type UpdateFileName = (typeof UPDATE_FILES)[number];

export interface DownloadResponse {
	status: number;
	text: string;
	bytes: ArrayBuffer;
}

/** GET over Obsidian's requestUrl (follows GitHub's redirects to the asset storage, no CORS). */
export type DownloadFn = (request: { url: string; headers?: Record<string, string> }) => Promise<DownloadResponse>;

/** Where a release was found: the user's LocalOCR server, or GitHub directly. */
export type UpdateSource = "server" | "github";

export interface UpdateOptions {
	/** The LocalOCR server URL (normalized); empty = GitHub only. */
	serverUrl?: string;
	repo?: string;
}

export interface ReleaseAsset {
	name: string;
	url: string;
	size: number;
	/** "sha256:<hex>": always from the server's latest.json, from GitHub when it reports one. */
	digest: string | null;
}

export interface PluginRelease {
	version: string;
	tag: string;
	notes: string;
	publishedAt: string;
	pageUrl: string;
	source: UpdateSource;
	/** From latest.json (the server read it from the verified manifest); null for GitHub (read from manifest.json). */
	minAppVersion: string | null;
	assets: Partial<Record<UpdateFileName, ReleaseAsset>>;
}

export type UpdateCheck =
	| { status: "up-to-date"; latest: PluginRelease | null }
	| { status: "available"; release: PluginRelease }
	/** The new version needs a newer Obsidian than this device has. */
	| { status: "needs-newer-obsidian"; release: PluginRelease; minAppVersion: string };

export class UpdateError extends Error {}

// ---------------------------------------------------------------------------
// Versions

/** "1.2.0" → [1, 2, 0]; null for anything else (pre-release versions are not offered). */
export function parseVersion(version: string): number[] | null {
	const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version.trim());
	return match ? match.slice(1).map(Number) : null;
}

/** Negative when a < b, 0 when equal, positive when a > b. Unparseable versions sort first. */
export function compareVersions(a: string, b: string): number {
	const pa = parseVersion(a);
	const pb = parseVersion(b);
	if (!pa || !pb) return (pa ? 1 : 0) - (pb ? 1 : 0);
	for (let i = 0; i < 3; i++) {
		if (pa[i] !== pb[i]) return pa[i] - pb[i];
	}
	return 0;
}

// ---------------------------------------------------------------------------
// Releases

const GITHUB_HEADERS = { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };

function asRecord(value: unknown): Record<string, unknown> | null {
	return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function str(value: unknown): string {
	return typeof value === "string" ? value : "";
}

/** The plugin releases in a GitHub releases listing (drafts, pre-releases and other tags skipped). */
export function parseReleases(json: unknown): PluginRelease[] {
	if (!Array.isArray(json)) throw new UpdateError("GitHub 回傳的版本清單格式不正確");
	const releases: PluginRelease[] = [];
	for (const item of json) {
		const release = asRecord(item);
		if (!release || release.draft === true || release.prerelease === true) continue;
		const tag = str(release.tag_name);
		if (!tag.startsWith(RELEASE_TAG_PREFIX)) continue;
		const version = tag.slice(RELEASE_TAG_PREFIX.length);
		if (!parseVersion(version)) continue;
		const assets: PluginRelease["assets"] = {};
		for (const rawAsset of Array.isArray(release.assets) ? release.assets : []) {
			const asset = asRecord(rawAsset);
			const name = str(asset?.name);
			if (!asset || !(UPDATE_FILES as readonly string[]).includes(name)) continue;
			assets[name as UpdateFileName] = {
				name,
				url: str(asset.browser_download_url),
				size: typeof asset.size === "number" ? asset.size : 0,
				digest: str(asset.digest) || null,
			};
		}
		if (!assets["main.js"]?.url || !assets["manifest.json"]?.url) continue;
		releases.push({
			version,
			tag,
			notes: str(release.body).trim(),
			publishedAt: str(release.published_at),
			pageUrl: str(release.html_url),
			source: "github",
			minAppVersion: null,
			assets,
		});
	}
	return releases.sort((a, b) => compareVersions(b.version, a.version));
}

/** latest.json from the LocalOCR server: every file must come with its URL (relative ones allowed) and SHA-256. */
export function parseServerRelease(json: unknown, serverUrl: string): PluginRelease {
	const release = asRecord(json);
	const files = asRecord(release?.files);
	const version = str(release?.version);
	if (!release || !files || !parseVersion(version)) throw new UpdateError("伺服器回傳的版本資訊格式不正確");
	const assets: PluginRelease["assets"] = {};
	for (const name of UPDATE_FILES) {
		const file = asRecord(files[name]);
		if (!file) continue;
		const sha256 = str(file.sha256).toLowerCase();
		let url = "";
		try {
			url = new URL(str(file.url), `${serverUrl}/`).href;
		} catch {
			// rejected below
		}
		if (!/^[0-9a-f]{64}$/.test(sha256) || !str(file.url) || !url) {
			throw new UpdateError(`伺服器回傳的 ${name} 缺少下載網址或 SHA-256`);
		}
		assets[name] = { name, url, size: typeof file.size === "number" ? file.size : 0, digest: `sha256:${sha256}` };
	}
	if (!assets["main.js"] || !assets["manifest.json"]) throw new UpdateError("伺服器回傳的版本資訊缺少 main.js 或 manifest.json");
	return {
		version,
		tag: `${RELEASE_TAG_PREFIX}${version}`,
		notes: str(release.notes).trim(),
		publishedAt: str(release.publishedAt),
		pageUrl: `${serverUrl}${SERVER_LATEST_PATH}`,
		source: "server",
		minAppVersion: str(release.minAppVersion),
		assets,
	};
}

/** For notices and the settings tab. */
export function describeSource(source: UpdateSource): string {
	return source === "server" ? "你的 Railway 伺服器" : "GitHub";
}

function describeStatus(response: DownloadResponse, source: UpdateSource): string {
	const { status } = response;
	if (source === "github" && (status === 403 || status === 429)) return "GitHub 暫時限制查詢次數，請稍後再試";
	if (status === 404) return "找不到更新來源";
	if (source === "server") {
		let code = "";
		try {
			code = str(asRecord(asRecord(JSON.parse(response.text))?.error)?.code);
		} catch {
			// not a JSON error body
		}
		if (code === "integrity_error") return "伺服器上的更新檔與紀錄的 SHA-256 不符，已停止更新（伺服器會在下次同步時修復）";
		return `你的 Railway 伺服器回應 ${status}`;
	}
	return `GitHub 回應 ${status}`;
}

async function get(download: DownloadFn, url: string, source: UpdateSource, headers?: Record<string, string>): Promise<DownloadResponse> {
	let response: DownloadResponse;
	try {
		response = await download({ url, headers });
	} catch (error) {
		const target = source === "server" ? "你的 Railway 伺服器" : " GitHub";
		throw new UpdateError(`無法連線到${target}：${error instanceof Error ? error.message : String(error)}`);
	}
	if (response.status < 200 || response.status >= 300) throw new UpdateError(describeStatus(response, source));
	return response;
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`逾時（${Math.round(ms / 1000)} 秒）`)), ms);
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error: unknown) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});
}

/** Server answers that mean "nothing to offer here": 404 (nothing mirrored yet, or an older server), 503 (no storage bucket). */
const SERVER_FALLBACK_STATUSES = [404, 503];

/**
 * The newest release on the user's LocalOCR server, or null when it has none to offer (404, 503, unreachable
 * or no answer within SERVER_TIMEOUT_MS): the caller then asks GitHub. Other failures are errors.
 */
export async function fetchServerRelease(
	download: DownloadFn,
	serverUrl: string,
	timeoutMs = SERVER_TIMEOUT_MS,
): Promise<PluginRelease | null> {
	const base = serverUrl.trim().replace(/\/+$/, "");
	let response: DownloadResponse;
	try {
		response = await withTimeout(download({ url: `${base}${SERVER_LATEST_PATH}` }), timeoutMs);
	} catch {
		return null;
	}
	if (SERVER_FALLBACK_STATUSES.includes(response.status)) return null;
	if (response.status < 200 || response.status >= 300) throw new UpdateError(describeStatus(response, "server"));
	let json: unknown;
	try {
		json = JSON.parse(response.text);
	} catch {
		throw new UpdateError("伺服器回傳的版本資訊不是有效的 JSON");
	}
	return parseServerRelease(json, base);
}

/** The newest published plugin release on GitHub, or null when there is none. */
export async function fetchGitHubRelease(download: DownloadFn, repo = UPDATE_REPO): Promise<PluginRelease | null> {
	const response = await get(download, `https://api.github.com/repos/${repo}/releases?per_page=50`, "github", GITHUB_HEADERS);
	let json: unknown;
	try {
		json = JSON.parse(response.text);
	} catch {
		throw new UpdateError("GitHub 回傳的版本清單不是有效的 JSON");
	}
	return parseReleases(json)[0] ?? null;
}

/** The newest release: from the LocalOCR server when it offers one, otherwise from GitHub. */
export async function fetchLatestRelease(
	download: DownloadFn,
	{ serverUrl = "", repo = UPDATE_REPO }: UpdateOptions = {},
): Promise<PluginRelease | null> {
	if (serverUrl.trim()) {
		const release = await fetchServerRelease(download, serverUrl);
		if (release) return release;
	}
	return fetchGitHubRelease(download, repo);
}

interface ReleaseManifest {
	id: string;
	version: string;
	minAppVersion: string;
}

/** Checks a downloaded manifest.json against the release it came from. */
export function parseReleaseManifest(text: string, release: PluginRelease): ReleaseManifest {
	let json: Record<string, unknown> | null;
	try {
		json = asRecord(JSON.parse(text));
	} catch {
		json = null;
	}
	if (!json) throw new UpdateError("新版本的 manifest.json 格式不正確");
	const manifest = { id: str(json.id), version: str(json.version), minAppVersion: str(json.minAppVersion) };
	if (manifest.id !== PLUGIN_ID) throw new UpdateError(`新版本的插件代碼不符（${manifest.id || "空白"}）`);
	if (manifest.version !== release.version) {
		throw new UpdateError(`新版本的 manifest.json 版本（${manifest.version || "空白"}）與發佈版本 ${release.version} 不符`);
	}
	return manifest;
}

/**
 * Compares the newest release with the installed version and checks that this device's Obsidian can run a newer
 * one (`supportsApp(minAppVersion)`): latest.json states minAppVersion, a GitHub release is downloaded as far as
 * its manifest.json.
 */
export async function checkForUpdate(
	download: DownloadFn,
	currentVersion: string,
	supportsApp: (minAppVersion: string) => boolean,
	options: UpdateOptions = {},
): Promise<UpdateCheck> {
	const latest = await fetchLatestRelease(download, options);
	if (!latest || compareVersions(latest.version, currentVersion) <= 0) return { status: "up-to-date", latest };
	const minAppVersion =
		latest.minAppVersion ??
		parseReleaseManifest((await get(download, (latest.assets["manifest.json"] as ReleaseAsset).url, latest.source)).text, latest)
			.minAppVersion;
	if (minAppVersion && !supportsApp(minAppVersion)) {
		return { status: "needs-newer-obsidian", release: latest, minAppVersion };
	}
	return { status: "available", release: latest };
}

function toHex(buffer: ArrayBuffer): string {
	return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** SHA-256 over Web Crypto (Obsidian desktop and mobile both have it). */
export async function sha256Hex(bytes: ArrayBuffer): Promise<string> {
	return toHex(await globalThis.crypto.subtle.digest("SHA-256", bytes));
}

/**
 * Downloads the release's files and verifies them: each file's SHA-256 (from latest.json, or the digest GitHub
 * reports), the manifest's id and version, and that main.js is the plugin bundle (not an error page).
 */
export async function downloadRelease(
	download: DownloadFn,
	release: PluginRelease,
	hash: (bytes: ArrayBuffer) => Promise<string> = sha256Hex,
): Promise<Partial<Record<UpdateFileName, string>>> {
	const files: Partial<Record<UpdateFileName, string>> = {};
	for (const name of UPDATE_FILES) {
		const asset = release.assets[name];
		if (!asset) continue;
		const response = await get(download, asset.url, release.source);
		if (asset.digest?.startsWith("sha256:")) {
			const expected = asset.digest.slice("sha256:".length).toLowerCase();
			if ((await hash(response.bytes)) !== expected) throw new UpdateError(`${name} 下載不完整或已被修改，已停止更新`);
		}
		files[name] = response.text;
	}
	parseReleaseManifest(files["manifest.json"] ?? "", release);
	const main = files["main.js"] ?? "";
	if (!main.includes("module.exports") || main.length < 1000) throw new UpdateError("下載的 main.js 不是插件程式，已停止更新");
	return files;
}

/** Whether an automatic check is due (none yet, or the last one is older than the interval). */
export function isCheckDue(lastCheckAt: string | null, now: number, interval = UPDATE_CHECK_INTERVAL_MS): boolean {
	const last = lastCheckAt ? Date.parse(lastCheckAt) : NaN;
	return !Number.isFinite(last) || now - last >= interval || last > now;
}

export function describeUpdateError(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
