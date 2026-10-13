import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
	PLUGIN_ID,
	checkForUpdate,
	compareVersions,
	downloadRelease,
	fetchLatestRelease,
	isCheckDue,
	parseReleases,
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
