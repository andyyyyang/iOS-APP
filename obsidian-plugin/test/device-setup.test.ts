import QRCode from "qrcode";
import { describe, expect, it } from "vitest";
import {
	PAIRING_NOTES_FOLDER,
	createPairingCode,
	describeSetupError,
	fetchRemotelySaveSetup,
	formatCountdown,
	isPluginEnabled,
	parsePairingCode,
	parseRemotelySaveSetup,
	remainingMs,
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
};

const uriFor = (vault: string) =>
	`obsidian://remotely-save?func=settings&version=localocr&vault=${encodeURIComponent(vault)}&data=${encodeURIComponent(JSON.stringify(SETTINGS))}`;

describe("createPairingCode", () => {
	it("POSTs the vault name and notes folder as JSON with the bearer token", async () => {
		const { client, requests } = recordingClient(() => ({ status: 201, body: PAIRING }));
		expect(await createPairingCode(client, "我的筆記")).toEqual(PAIRING);
		expect(requests).toHaveLength(1);
		const [req] = requests;
		expect(req.url).toBe("https://ocr.example.com/v1/pairing");
		expect(req.method).toBe("POST");
		expect(req.headers.Authorization).toBe(`Bearer ${KEY}`);
		expect(req.headers["Content-Type"]).toBe("application/json");
		expect(JSON.parse(req.body!)).toEqual({ vaultName: "我的筆記", notesFolder: "iPad 筆記" });
		expect(PAIRING_NOTES_FOLDER).toBe("iPad 筆記");
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
