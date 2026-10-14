import QRCode from "qrcode";
import { describe, expect, it } from "vitest";
import {
	createPairingCode,
	describeSetupError,
	fetchRemotelySaveSetup,
	findProtocolHandler,
	formatCountdown,
	isPluginEnabled,
	parsePairingCode,
	parseRemotelySaveSetup,
	remainingMs,
	remotelySaveImportParams,
} from "../src/device-setup";
import { ApiError, LocalOcrClient, type HttpFn, type HttpRequest } from "../src/sync-core";

const KEY = "secret-key-123";

function recordingClient(responder: (req: HttpRequest) => { status: number; body?: unknown }) {
	const requests: HttpRequest[] = [];
	const http: HttpFn = async (req) => {
		requests.push(req);
		const { status, body } = responder(req);
		return { status, text: body === undefined ? "" : JSON.stringify(body) };
	};
	return { client: new LocalOcrClient("https://ocr.example.com/", KEY, http), requests };
}

const PAIRING = {
	code: "K7QM-3XPA",
	expiresAt: "2026-10-13T00:10:00.000Z",
	pairUrl: "localocr://pair?server=https%3A%2F%2Focr.example.com&code=K7QM-3XPA",
};

const SETTINGS = {
	serviceType: "s3",
	s3: {
		s3Endpoint: "https://t3.storageapi.dev",
		s3Region: "auto",
		s3AccessKeyID: `tid_${"a".repeat(30)}`,
		s3SecretAccessKey: `tsec_${"b".repeat(60)}`,
		s3BucketName: "obsidian-vault-jdhhd8oe18xi",
		partsConcurrency: 20,
		forcePathStyle: false,
		remotePrefix: "",
		useAccurateMTime: true,
		reverseProxyNoSignUrl: "",
		generateFolderObject: false,
		bypassCorsLocally: true,
	},
	autoRunEveryMilliseconds: 300000,
	initRunAfterMilliseconds: 10000,
	syncOnSaveAfterMilliseconds: 1000,
	agreeToUseSyncV3: true,
	syncUnderscoreItems: true,
};

const uriFor = (vault: string) =>
	`obsidian://remotely-save?func=settings&version=localocr&vault=${encodeURIComponent(vault)}&data=${encodeURIComponent(JSON.stringify(SETTINGS))}`;

describe("createPairingCode", () => {
	it("POSTs the vault name (no notes folder: the whole vault syncs) as JSON with the bearer token", async () => {
		const { client, requests } = recordingClient(() => ({ status: 201, body: PAIRING }));
		expect(await createPairingCode(client, "我的筆記")).toEqual(PAIRING);
		expect(requests).toHaveLength(1);
		const [req] = requests;
		expect(req.url).toBe("https://ocr.example.com/v1/pairing");
		expect(req.method).toBe("POST");
		expect(req.headers.Authorization).toBe(`Bearer ${KEY}`);
		expect(req.headers["Content-Type"]).toBe("application/json");
		expect(JSON.parse(req.body!)).toEqual({ vaultName: "我的筆記" });
	});

	it("sends no body or Content-Type on GET requests", async () => {
		const { client, requests } = recordingClient(() => ({ status: 200, body: { items: [] } }));
		await client.listTemplates();
		expect(requests[0].method).toBe("GET");
		expect(requests[0].body).toBeUndefined();
		expect(requests[0].headers["Content-Type"]).toBeUndefined();
	});

	it("rejects malformed responses", () => {
		for (const body of [null, [], {}, { ...PAIRING, code: 5 }, { ...PAIRING, expiresAt: "soon" }, { ...PAIRING, pairUrl: null }]) {
			expect(() => parsePairingCode(body)).toThrow(ApiError);
		}
		try {
			parsePairingCode({});
		} catch (error) {
			expect((error as ApiError).code).toBe("bad_response");
		}
	});
});

describe("fetchRemotelySaveSetup", () => {
	it("asks for the current vault (URL-encoded) and returns the settings and import URI", async () => {
		const vault = "我的筆記 & Co";
		const { client, requests } = recordingClient(() => ({ status: 200, body: { settings: SETTINGS, uri: uriFor(vault) } }));
		const setup = await fetchRemotelySaveSetup(client, vault);
		expect(requests[0].url).toBe(`https://ocr.example.com/v1/vault/remotely-save?vault=${encodeURIComponent(vault)}`);
		expect(requests[0].method).toBe("GET");
		expect(requests[0].headers.Authorization).toBe(`Bearer ${KEY}`);
		expect(setup).toEqual({ settings: SETTINGS, uri: uriFor(vault) });
	});

	it("rejects a response without a Remotely Save URI", () => {
		expect(() => parseRemotelySaveSetup({ settings: SETTINGS, uri: null })).toThrow(ApiError);
		expect(() => parseRemotelySaveSetup({ settings: SETTINGS, uri: "https://evil.example.com" })).toThrow(ApiError);
		expect(() => parseRemotelySaveSetup({ settings: [], uri: uriFor("v") })).toThrow(ApiError);
	});

	it("produces a URI that fits in a QR code", () => {
		const uri = uriFor("我的筆記");
		expect(QRCode.create(uri, { errorCorrectionLevel: "L" }).version).toBeLessThanOrEqual(25);
	});
});

describe("describeSetupError", () => {
	async function failure(status: number, body?: unknown): Promise<unknown> {
		const { client } = recordingClient(() => ({ status, body }));
		return fetchRemotelySaveSetup(client, "v").then(
			() => {
				throw new Error("expected a failure");
			},
			(error: unknown) => error,
		);
	}

	it("explains a server without vault storage", async () => {
		const error = await failure(503, {
			error: { code: "vault_not_configured", message: "Vault storage is not configured (set VAULT_S3_* variables)" },
		});
		expect(describeSetupError(error)).toContain("VAULT_S3_*");
		expect(describeSetupError(error)).toContain("尚未設定");
	});

	it("points to the API key on 401 and to an old server on 404", async () => {
		const unauthorized = describeSetupError(await failure(401, { error: { code: "unauthorized", message: "Missing or invalid API key" } }));
		expect(unauthorized).toContain("401");
		expect(unauthorized).toContain("API 金鑰");
		expect(unauthorized).not.toContain(KEY);
		const missing = describeSetupError(await failure(404, { error: { code: "not_found", message: "Route not found" } }));
		expect(missing).toContain("舊版");
	});

	it("falls back to the plain message", async () => {
		expect(describeSetupError(await failure(500))).toContain("伺服器錯誤（500）");
		expect(describeSetupError(new Error("boom"))).toBe("boom");
		const { client } = recordingClient(() => ({ status: 200 }));
		const noKey = new LocalOcrClient("https://ocr.example.com", "", async () => ({ status: 200, text: "" }));
		expect(describeSetupError(await createPairingCode(noKey, "v").catch((e: unknown) => e))).toBe("尚未設定 API 金鑰");
		expect(describeSetupError(await createPairingCode(client, "v").catch((e: unknown) => e))).toContain("不是有效的 JSON");
	});
});

describe("countdown", () => {
	const now = Date.parse("2026-10-13T00:00:00.000Z");

	it("computes the time left and never goes negative", () => {
		expect(remainingMs(PAIRING.expiresAt, now)).toBe(600_000);
		expect(remainingMs(PAIRING.expiresAt, now + 700_000)).toBe(0);
		expect(remainingMs("not a date", now)).toBe(0);
	});

	it("formats m:ss, rounding seconds up", () => {
		expect(formatCountdown(600_000)).toBe("10:00");
		expect(formatCountdown(599_001)).toBe("10:00");
		expect(formatCountdown(599_000)).toBe("9:59");
		expect(formatCountdown(61_000)).toBe("1:01");
		expect(formatCountdown(500)).toBe("0:01");
		expect(formatCountdown(0)).toBe("0:00");
		expect(formatCountdown(-5)).toBe("0:00");
		expect(formatCountdown(Number.NaN)).toBe("0:00");
	});
});

describe("isPluginEnabled", () => {
	it("reads app.plugins.enabledPlugins defensively", () => {
		expect(isPluginEnabled({ plugins: { enabledPlugins: new Set(["remotely-save"]) } }, "remotely-save")).toBe(true);
		expect(isPluginEnabled({ plugins: { enabledPlugins: new Set(["dataview"]) } }, "remotely-save")).toBe(false);
		expect(isPluginEnabled({ plugins: {} }, "remotely-save")).toBeNull();
		expect(isPluginEnabled({ plugins: { enabledPlugins: ["remotely-save"] } }, "remotely-save")).toBeNull();
		expect(isPluginEnabled({}, "remotely-save")).toBeNull();
		expect(isPluginEnabled(null, "remotely-save")).toBeNull();
	});
});

describe("findProtocolHandler", () => {
	const handler = () => undefined;
	it("finds a handler in either private registry", () => {
		expect(findProtocolHandler({ workspace: { protocolHandlers: new Map([["remotely-save", handler]]) } }, "remotely-save")).toBe(handler);
		expect(findProtocolHandler({ workspace: { protocolHandler: { handlers: new Map([["remotely-save", handler]]) } } }, "remotely-save")).toBe(handler);
	});
	it("returns null when the registry or handler is missing", () => {
		expect(findProtocolHandler({ workspace: { protocolHandlers: new Map([["other", handler]]) } }, "remotely-save")).toBeNull();
		expect(findProtocolHandler({ workspace: { protocolHandlers: new Map([["remotely-save", "nope"]]) } }, "remotely-save")).toBeNull();
		expect(findProtocolHandler({ workspace: {} }, "remotely-save")).toBeNull();
		expect(findProtocolHandler(null, "remotely-save")).toBeNull();
	});
});

describe("remotelySaveImportParams", () => {
	const settings = { serviceType: "s3", s3: { s3Endpoint: "https://s3.example.com", s3SecretAccessKey: "a+b/c=&d" } };
	const data = JSON.stringify(settings);
	const uri = `obsidian://remotely-save?func=settings&version=localocr&vault=${encodeURIComponent("andy jentech")}&data=${encodeURIComponent(data)}`;

	it("decodes the URI like Obsidian does and keeps the vault Remotely Save requires", () => {
		const params = remotelySaveImportParams({ settings, uri }, "andy jentech");
		expect(params).toEqual({ func: "settings", version: "localocr", vault: "andy jentech", data, action: "remotely-save" });
		expect(JSON.parse(params.data)).toEqual(settings);
	});

	it("uses the vault that is open now", () => {
		expect(remotelySaveImportParams({ settings, uri }, "工作").vault).toBe("工作");
	});

	it("falls back to the settings object when the URI has no query", () => {
		const params = remotelySaveImportParams({ settings, uri: "obsidian://remotely-save" }, "v");
		expect(params).toEqual({ func: "settings", version: "localocr", data, action: "remotely-save", vault: "v" });
	});
});
