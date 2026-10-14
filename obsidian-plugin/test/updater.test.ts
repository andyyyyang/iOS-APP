import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
	PLUGIN_ID,
	checkForUpdate,
	compareVersions,
	downloadRelease,
	fetchLatestRelease,
	fetchServerRelease,
	isCheckDue,
	parseReleases,
	parseServerRelease,
	parseVersion,
	sha256Hex,
	type DownloadFn,
	type PluginRelease,
} from "../src/updater";

const MAIN_JS = `/* LocalOCR Sync */\n"use strict";\n${"var x = 1;\n".repeat(200)}module.exports = __toCommonJS(main_exports);\n`;
const manifestFor = (version: string, extra: Record<string, unknown> = {}) =>
	JSON.stringify({ id: PLUGIN_ID, name: "LocalOCR Sync", version, minAppVersion: "1.5.0", ...extra });
const sha = (text: string) => `sha256:${createHash("sha256").update(text).digest("hex")}`;

function release(version: string, opts: { tag?: string; draft?: boolean; prerelease?: boolean; files?: Record<string, string> } = {}) {
	const files = opts.files ?? { "main.js": MAIN_JS, "manifest.json": manifestFor(version) };
	const tag = opts.tag ?? `obsidian-plugin-${version}`;
	return {
		tag_name: tag,
		draft: opts.draft ?? false,
		prerelease: opts.prerelease ?? false,
		body: `- 第一項\n- 第二項`,
		published_at: "2026-10-14T00:00:00Z",
		html_url: `https://github.com/andyyyyang/iOS-APP/releases/tag/${tag}`,
		assets: Object.entries(files).map(([name, text]) => ({
			name,
			size: text.length,
			digest: sha(text),
			browser_download_url: `https://github.com/andyyyyang/iOS-APP/releases/download/${tag}/${name}`,
		})),
	};
}

/** Fake GitHub: the releases listing plus every asset's content by URL. */
function fakeGitHub(releases: ReturnType<typeof release>[], contents: Record<string, string> = {}, status = 200) {
	const requests: string[] = [];
	const byUrl = new Map<string, string>(Object.entries(contents));
	for (const r of releases) {
		const version = r.tag_name.replace("obsidian-plugin-", "");
		for (const asset of r.assets) {
			if (!byUrl.has(asset.browser_download_url)) {
				byUrl.set(asset.browser_download_url, asset.name === "main.js" ? MAIN_JS : manifestFor(version));
			}
		}
	}
	const download: DownloadFn = async ({ url }) => {
		requests.push(url);
		if (url.startsWith("https://api.github.com/")) {
			const text = status === 200 ? JSON.stringify(releases) : "{}";
			return { status, text, bytes: new TextEncoder().encode(text).buffer as ArrayBuffer };
		}
		const text = byUrl.get(url);
		if (text === undefined) return { status: 404, text: "Not Found", bytes: new ArrayBuffer(0) };
		return { status: 200, text, bytes: new TextEncoder().encode(text).buffer as ArrayBuffer };
	};
	return { download, requests };
}

const SERVER = "https://ocr.example.com";
const LATEST_URL = `${SERVER}/obsidian-plugin/latest.json`;
const hex = (text: string) => createHash("sha256").update(text).digest("hex");
const toBytes = (text: string) => new TextEncoder().encode(text).buffer as ArrayBuffer;

/** The server's latest.json for `files` (each file's SHA-256 is of the text given here). */
function latestJson(
	version: string,
	files: Record<string, string> = { "main.js": MAIN_JS, "manifest.json": manifestFor(version) },
	extra: Record<string, unknown> = {},
) {
	return {
		version,
		minAppVersion: "1.5.0",
		notes: "- 伺服器上的新版本\n",
		publishedAt: "2026-10-14T00:00:00.000Z",
		files: Object.fromEntries(
			Object.entries(files).map(([name, text]) => [
				name,
				{ sha256: hex(text), size: text.length, url: `${SERVER}/obsidian-plugin/releases/${version}/${name}` },
			]),
		),
		...extra,
	};
}

/**
 * Fake LocalOCR server in front of a fake GitHub: latest.json (with `status`, or a network failure / no answer)
 * and its files by URL (the texts latest.json was built from, overridden by `contents`).
 */
function fakeServer(
	latest: ReturnType<typeof latestJson> | null,
	opts: {
		status?: number;
		body?: string;
		contents?: Record<string, { status: number; text: string }>;
		github?: ReturnType<typeof fakeGitHub>;
		network?: "down" | "hang";
	} = {},
) {
	const github = opts.github ?? fakeGitHub([release("1.3.0")]);
	const files = new Map<string, { status: number; text: string }>();
	if (latest) {
		for (const [name, file] of Object.entries(latest.files)) {
			const version = latest.version;
			files.set(file.url, { status: 200, text: name === "main.js" ? MAIN_JS : manifestFor(version) });
		}
	}
	for (const [url, response] of Object.entries(opts.contents ?? {})) files.set(url, response);
	const requests: { url: string; headers?: Record<string, string> }[] = [];
	const download: DownloadFn = async (request) => {
		if (!request.url.startsWith(SERVER)) return github.download(request);
		requests.push(request);
		if (opts.network === "down") throw new Error("net::ERR_NAME_NOT_RESOLVED");
		if (opts.network === "hang") return new Promise<never>(() => {});
		if (request.url === LATEST_URL) {
			const text = opts.body ?? (latest ? JSON.stringify(latest) : '{"error":{"code":"not_found","message":"x"}}');
			return { status: opts.status ?? (latest ? 200 : 404), text, bytes: toBytes(text) };
		}
		const file = files.get(request.url) ?? { status: 404, text: '{"error":{"code":"not_found"}}' };
		return { ...file, bytes: toBytes(file.text) };
	};
	return { download, requests, github };
}

describe("versions", () => {
	it("parses and compares x.y.z versions numerically", () => {
		expect(parseVersion("1.10.0")).toEqual([1, 10, 0]);
		expect(parseVersion("1.2")).toBeNull();
		expect(parseVersion("1.2.0-beta.1")).toBeNull();
		expect(compareVersions("1.10.0", "1.9.9")).toBeGreaterThan(0);
		expect(compareVersions("1.2.0", "1.2.0")).toBe(0);
		expect(compareVersions("1.1.1", "1.2.0")).toBeLessThan(0);
	});
});

describe("parseReleases", () => {
	it("keeps only published plugin releases with main.js and manifest.json, newest first", () => {
		const list = parseReleases([
			release("1.2.0"),
			release("1.10.0"),
			release("2.0.0", { draft: true }),
			release("1.11.0", { prerelease: true }),
			release("9.9.9", { tag: "ios-9.9.9" }),
			release("1.12.0", { files: { "main.js": MAIN_JS } }),
		]);
		expect(list.map((r) => r.version)).toEqual(["1.10.0", "1.2.0"]);
		expect(list[0].assets["main.js"]?.digest).toBe(sha(MAIN_JS));
		expect(list[0].notes).toBe("- 第一項\n- 第二項");
	});

	it("rejects a listing that is not an array", () => {
		expect(() => parseReleases({ message: "rate limited" })).toThrow("格式不正確");
	});
});

describe("checkForUpdate", () => {
	const supports = () => true;

	it("reports up to date when the newest release is not newer", async () => {
		const { download, requests } = fakeGitHub([release("1.2.0")]);
		expect(await checkForUpdate(download, "1.2.0", supports)).toMatchObject({ status: "up-to-date" });
		expect(requests).toEqual(["https://api.github.com/repos/andyyyyang/iOS-APP/releases?per_page=50"]);
	});

	it("offers a newer release after checking its manifest", async () => {
		const { download } = fakeGitHub([release("1.3.0"), release("1.2.0")]);
		const result = await checkForUpdate(download, "1.2.0", supports);
		expect(result.status).toBe("available");
		expect(result.status === "available" && result.release.version).toBe("1.3.0");
	});

	it("holds back a release that needs a newer Obsidian", async () => {
		const r = release("1.3.0", { files: { "main.js": MAIN_JS, "manifest.json": manifestFor("1.3.0", { minAppVersion: "9.0.0" }) } });
		const { download } = fakeGitHub([r], { [r.assets[1].browser_download_url]: manifestFor("1.3.0", { minAppVersion: "9.0.0" }) });
		const result = await checkForUpdate(download, "1.2.0", (min) => min === "1.5.0");
		expect(result).toMatchObject({ status: "needs-newer-obsidian", minAppVersion: "9.0.0" });
	});

	it("explains GitHub rate limits", async () => {
		const { download } = fakeGitHub([], {}, 403);
		await expect(fetchLatestRelease(download)).rejects.toThrow("限制查詢次數");
	});
});

describe("downloadRelease", () => {
	const latest = async (download: DownloadFn) => (await fetchLatestRelease(download)) as PluginRelease;

	it("downloads and verifies main.js and manifest.json", async () => {
		const { download } = fakeGitHub([release("1.3.0")]);
		const files = await downloadRelease(download, await latest(download));
		expect(files["main.js"]).toBe(MAIN_JS);
		expect(JSON.parse(files["manifest.json"] ?? "{}").version).toBe("1.3.0");
	});

	it("stops when a file does not match GitHub's digest", async () => {
		const r = release("1.3.0");
		const { download } = fakeGitHub([r], { [r.assets[0].browser_download_url]: MAIN_JS.replace("var x", "var y") });
		await expect(downloadRelease(download, await latest(download))).rejects.toThrow("main.js 下載不完整或已被修改");
	});

	it("rejects a manifest for another plugin or version", async () => {
		const files = { "main.js": MAIN_JS, "manifest.json": manifestFor("1.3.0", { id: "other-plugin" }) };
		const { download } = fakeGitHub([release("1.3.0", { files })], {
			"https://github.com/andyyyyang/iOS-APP/releases/download/obsidian-plugin-1.3.0/manifest.json": files["manifest.json"],
		});
		await expect(downloadRelease(download, await latest(download))).rejects.toThrow("插件代碼不符");
	});

	it("rejects a main.js that is not the plugin bundle", async () => {
		const files = { "main.js": "<html>error</html>", "manifest.json": manifestFor("1.3.0") };
		const { download } = fakeGitHub([release("1.3.0", { files })], {
			"https://github.com/andyyyyang/iOS-APP/releases/download/obsidian-plugin-1.3.0/main.js": files["main.js"],
		});
		await expect(downloadRelease(download, await latest(download))).rejects.toThrow("不是插件程式");
	});
});

describe("helpers", () => {
	it("hashes with Web Crypto like GitHub's sha256 digests", async () => {
		const bytes = new TextEncoder().encode(MAIN_JS).buffer as ArrayBuffer;
		expect(`sha256:${await sha256Hex(bytes)}`).toBe(sha(MAIN_JS));
	});

	it("runs automatic checks at most every 6 hours", () => {
		const now = Date.parse("2026-10-14T12:00:00Z");
		expect(isCheckDue(null, now)).toBe(true);
		expect(isCheckDue("2026-10-14T07:00:00Z", now)).toBe(false);
		expect(isCheckDue("2026-10-14T05:59:00Z", now)).toBe(true);
		expect(isCheckDue("2026-10-15T00:00:00Z", now), "a clock moved backwards does not block checks").toBe(true);
		expect(isCheckDue("not a date", now)).toBe(true);
	});
});

describe("updates from the LocalOCR server", () => {
	const supports = () => true;
	const fromServer = { serverUrl: SERVER };

	it("reads the server's latest.json first and installs from it without asking GitHub", async () => {
		const server = fakeServer(latestJson("1.3.0"), { github: fakeGitHub([release("1.2.0")]) });
		const result = await checkForUpdate(server.download, "1.2.0", supports, fromServer);
		expect(result.status).toBe("available");
		if (result.status !== "available") return;
		expect(result.release).toMatchObject({ version: "1.3.0", source: "server", minAppVersion: "1.5.0", notes: "- 伺服器上的新版本" });
		// minAppVersion came with latest.json: no manifest download for the check, no API key header
		expect(server.requests).toEqual([{ url: LATEST_URL }]);

		const files = await downloadRelease(server.download, result.release);
		expect(files["main.js"]).toBe(MAIN_JS);
		expect(JSON.parse(files["manifest.json"] ?? "{}").version).toBe("1.3.0");
		expect(server.requests.map((r) => r.url)).toEqual([
			LATEST_URL,
			`${SERVER}/obsidian-plugin/releases/1.3.0/main.js`,
			`${SERVER}/obsidian-plugin/releases/1.3.0/manifest.json`,
		]);
		expect(server.github.requests).toEqual([]);
	});

	it("reports up to date from the server and accepts a trailing slash in the server URL", async () => {
		const server = fakeServer(latestJson("1.3.0"));
		const result = await checkForUpdate(server.download, "1.3.0", supports, { serverUrl: `${SERVER}/` });
		expect(result).toMatchObject({ status: "up-to-date", latest: { version: "1.3.0", source: "server" } });
		expect(server.requests.map((r) => r.url)).toEqual([LATEST_URL]);
	});

	it("holds back a server release that needs a newer Obsidian (minAppVersion from latest.json)", async () => {
		const server = fakeServer(latestJson("1.3.0", undefined, { minAppVersion: "9.0.0" }));
		const result = await checkForUpdate(server.download, "1.2.0", (min) => min === "1.5.0", fromServer);
		expect(result).toMatchObject({ status: "needs-newer-obsidian", minAppVersion: "9.0.0" });
	});

	it("stops when a downloaded file does not match latest.json's SHA-256", async () => {
		const server = fakeServer(latestJson("1.3.0"), {
			contents: { [`${SERVER}/obsidian-plugin/releases/1.3.0/main.js`]: { status: 200, text: MAIN_JS.replace("var x", "var y") } },
		});
		const latest = (await fetchLatestRelease(server.download, fromServer)) as PluginRelease;
		await expect(downloadRelease(server.download, latest)).rejects.toThrow("main.js 下載不完整或已被修改");
	});

	it("keeps the manifest and main.js checks for server releases", async () => {
		const cases: [Record<string, string>, string][] = [
			[{ "main.js": MAIN_JS, "manifest.json": manifestFor("1.3.0", { id: "other-plugin" }) }, "插件代碼不符"],
			[{ "main.js": MAIN_JS, "manifest.json": manifestFor("1.2.9") }, "與發佈版本 1.3.0 不符"],
			[{ "main.js": "<html>error</html>", "manifest.json": manifestFor("1.3.0") }, "不是插件程式"],
		];
		for (const [files, message] of cases) {
			const latest = latestJson("1.3.0", files);
			const contents = Object.fromEntries(
				Object.entries(files).map(([name, text]) => [`${SERVER}/obsidian-plugin/releases/1.3.0/${name}`, { status: 200, text }]),
			);
			const server = fakeServer(latest, { contents });
			const release = (await fetchLatestRelease(server.download, fromServer)) as PluginRelease;
			await expect(downloadRelease(server.download, release)).rejects.toThrow(message);
		}
	});

	it("explains a file the server refuses because its storage copy was changed", async () => {
		const server = fakeServer(latestJson("1.3.0"), {
			contents: {
				[`${SERVER}/obsidian-plugin/releases/1.3.0/main.js`]: {
					status: 502,
					text: '{"error":{"code":"integrity_error","message":"main.js of 1.3.0 in storage does not match its recorded SHA-256"}}',
				},
			},
		});
		const latest = (await fetchLatestRelease(server.download, fromServer)) as PluginRelease;
		await expect(downloadRelease(server.download, latest)).rejects.toThrow("伺服器上的更新檔與紀錄的 SHA-256 不符");
	});

	it("falls back to GitHub when the server has nothing to offer (404, 503, unreachable, no answer)", async () => {
		const servers = [
			fakeServer(null), // 404: nothing mirrored yet, or a server without this endpoint
			fakeServer(null, { status: 503, body: '{"error":{"code":"vault_not_configured","message":"x"}}' }),
			fakeServer(latestJson("1.4.0"), { network: "down" }),
		];
		for (const server of servers) {
			const latest = await fetchLatestRelease(server.download, fromServer);
			expect(latest).toMatchObject({ version: "1.3.0", source: "github", minAppVersion: null });
			expect(server.requests.map((r) => r.url)).toEqual([LATEST_URL]);
			expect(server.github.requests).toEqual(["https://api.github.com/repos/andyyyyang/iOS-APP/releases?per_page=50"]);
		}
		const hanging = fakeServer(latestJson("1.4.0"), { network: "hang" });
		expect(await fetchServerRelease(hanging.download, SERVER, 10)).toBeNull();
	});

	it("checks a GitHub fallback release through its manifest, as before", async () => {
		const server = fakeServer(null);
		const result = await checkForUpdate(server.download, "1.2.0", supports, fromServer);
		expect(result).toMatchObject({ status: "available", release: { version: "1.3.0", source: "github" } });
		expect(server.github.requests).toContain("https://github.com/andyyyyang/iOS-APP/releases/download/obsidian-plugin-1.3.0/manifest.json");
	});

	it("asks only GitHub without a server URL", async () => {
		const server = fakeServer(latestJson("1.4.0"));
		const latest = await fetchLatestRelease(server.download, { serverUrl: "  " });
		expect(latest).toMatchObject({ version: "1.3.0", source: "github" });
		expect(server.requests).toEqual([]);
	});

	it("reports other server failures instead of falling back", async () => {
		const cases: [ReturnType<typeof fakeServer>, string][] = [
			[fakeServer(latestJson("1.3.0"), { status: 500, body: "{}" }), "你的 Railway 伺服器回應 500"],
			[fakeServer(latestJson("1.3.0"), { body: "<html>" }), "不是有效的 JSON"],
			[fakeServer(latestJson("1.3.0"), { body: JSON.stringify({ version: "1.3" }) }), "格式不正確"],
			[
				fakeServer(latestJson("1.3.0"), {
					body: JSON.stringify({ ...latestJson("1.3.0"), files: { "main.js": { url: "/x" }, "manifest.json": { url: "/y" } } }),
				}),
				"main.js 缺少下載網址或 SHA-256",
			],
			[
				fakeServer(latestJson("1.3.0"), { body: JSON.stringify(latestJson("1.3.0", { "main.js": MAIN_JS })) }),
				"缺少 main.js 或 manifest.json",
			],
		];
		for (const [server, message] of cases) {
			await expect(fetchLatestRelease(server.download, fromServer)).rejects.toThrow(message);
			expect(server.github.requests).toEqual([]);
		}
	});

	it("resolves relative file URLs against the server", () => {
		const latest = latestJson("1.3.0");
		latest.files["main.js"].url = "/obsidian-plugin/releases/1.3.0/main.js";
		const release = parseServerRelease(latest, SERVER);
		expect(release.assets["main.js"]).toEqual({
			name: "main.js",
			url: `${SERVER}/obsidian-plugin/releases/1.3.0/main.js`,
			size: MAIN_JS.length,
			digest: `sha256:${hex(MAIN_JS)}`,
		});
		expect(release.pageUrl).toBe(LATEST_URL);
	});
});
