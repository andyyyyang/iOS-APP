import { Notice, Plugin, TAbstractFile, TFile, TFolder, debounce, normalizePath, requestUrl, requireApiVersion } from "obsidian";
import { DEFAULT_SETTINGS, LocalOcrSettingTab, describeProgress, loadSettings, type LocalOcrSettings } from "./settings";
import {
	buildNotePath,
	formatClock,
	formatDateTime,
	mergeNote,
	renderNote,
	resolveTemplateName,
	uniquePath,
	type RenderOptions,
} from "./format";
import {
	findMapping,
	parseFieldList,
	prepareRecord,
	upsertIntoJsonText,
	type JsonOutcome,
	type JsonRecordRef,
	type UpsertOptions,
} from "./json-export";
import {
	LocalOcrClient,
	SyncAbortedError,
	describeError,
	initialCursorState,
	normalizeServerUrl,
	runSync,
	summarize,
	type HttpFn,
} from "./sync-core";
import type { Scan, SyncCursorState, WriteOutcome } from "./types";
import { createPairingCode, describeSetupError, fetchRemotelySaveSetup } from "./device-setup";
import { PairingModal, RemotelySaveModal } from "./setup-modals";
import {
	UPDATE_CHECK_INTERVAL_MS,
	UPDATE_FILES,
	checkForUpdate,
	describeSource,
	describeUpdateError,
	downloadRelease,
	isCheckDue,
	type DownloadFn,
	type PluginRelease,
	type UpdateCheck,
	type UpdateFileName,
} from "./updater";

interface SyncMeta {
	lastSyncAt: string | null;
	lastSyncCount: number;
}

interface UpdateMeta {
	lastCheckAt: string | null;
	/** Version already announced (so a notice is not repeated on every check). */
	notifiedVersion: string | null;
}

interface PluginData {
	settings: LocalOcrSettings;
	update: UpdateMeta;
	sync: SyncCursorState;
	meta: SyncMeta;
	/** scan id → vault path of its note */
	paths: Record<string, string>;
	/** scan id → JSON array file and record id written for it */
	jsonRecords: Record<string, JsonRecordRef>;
}

const LOG_PREFIX = "[LocalOCR Sync]";
const STARTUP_SYNC_DELAY_MS = 5_000;
const UPDATE_STARTUP_DELAY_MS = 20_000;

/** Obsidian's plugin manager (internal API: the same calls BRAT uses to reload an updated plugin). */
interface PluginManager {
	loadManifests(): Promise<void>;
	disablePlugin(id: string): Promise<void>;
	enablePlugin(id: string): Promise<boolean>;
}

/** Downloads over requestUrl (follows GitHub's redirects, no CORS, works on mobile). */
const obsidianDownload: DownloadFn = async ({ url, headers }) => {
	const response = await requestUrl({ url, headers, throw: false });
	let text = "";
	let bytes = new ArrayBuffer(0);
	try {
		text = response.text;
	} catch {
		// not text: the caller rejects it
	}
	try {
		bytes = response.arrayBuffer;
	} catch {
		// no body: a digest check fails
	}
	return { status: response.status, text, bytes };
};

/** HTTP transport over Obsidian's requestUrl (no CORS, works on mobile). */
const obsidianHttp: HttpFn = async (request) => {
	const response = await requestUrl({
		url: request.url,
		method: request.method,
		headers: request.headers,
		body: request.body,
		throw: false,
	});
	let text = "";
	try {
		text = response.text;
	} catch {
		text = "";
	}
	return { status: response.status, text };
};

export default class LocalOcrSyncPlugin extends Plugin {
	settings: LocalOcrSettings = { ...DEFAULT_SETTINGS };
	private syncState: SyncCursorState = initialCursorState();
	private meta: SyncMeta = { lastSyncAt: null, lastSyncCount: 0 };
	private paths: Record<string, string> = {};
	private jsonRecords: Record<string, JsonRecordRef> = {};
	private updateMeta: UpdateMeta = { lastCheckAt: null, notifiedVersion: null };
	/** Result of the latest update check (shown in the settings tab). */
	private lastUpdateCheck: UpdateCheck | null = null;
	/** An update found during a sync: installed when the sync ends. */
	private pendingUpdate: PluginRelease | null = null;
	private updating = false;
	private updateTimer: number | null = null;

	private syncing = false;
	private unloaded = false;
	private lastSyncFailed = false;
	private autoSyncTimer: number | null = null;
	private startupTimer: number | null = null;
	private statusBarEl: HTMLElement | null = null;
	/** localocr_id → file, built lazily from the metadata cache once per sync. */
	private frontmatterIndex: Map<string, TFile> | null = null;
	private readonly requestSave = debounce(() => void this.savePluginData(), 1000, true);

	async onload(): Promise<void> {
		await this.loadPluginData();
		this.addSettingTab(new LocalOcrSettingTab(this.app, this));

		this.statusBarEl = this.addStatusBarItem();
		this.statusBarEl.addClass("mod-clickable");
		this.registerDomEvent(this.statusBarEl, "click", () => void this.sync({ manual: true }));
		this.renderIdleStatus();

		this.addRibbonIcon("scan-text", "立即同步 LocalOCR", () => void this.sync({ manual: true }));

		this.addCommand({
			id: "sync-now",
			name: "立即同步 LocalOCR",
			callback: () => void this.sync({ manual: true }),
		});
		this.addCommand({
			id: "resync-all",
			name: "重新同步全部（重設進度）",
			callback: async () => {
				if (await this.resetProgress(false)) await this.sync({ manual: true });
			},
		});

		this.addCommand({
			id: "pair-device",
			name: "配對 iPhone／iPad",
			callback: () => void this.openPairing(),
		});
		this.addCommand({
			id: "setup-remotely-save",
			name: "設定 Remotely Save（同步 vault）",
			callback: () => void this.openRemotelySaveSetup(),
		});
		this.addCommand({
			id: "update-plugin",
			name: "檢查並更新插件",
			callback: () => void this.checkForUpdates({ manual: true }),
		});

		this.registerEvent(this.app.vault.on("rename", (file, oldPath) => this.onFileRenamed(file, oldPath)));
		this.registerEvent(this.app.vault.on("delete", (file) => this.onFileDeleted(file)));

		this.app.workspace.onLayoutReady(() => {
			this.updateTimer = window.setTimeout(() => {
				this.updateTimer = null;
				void this.checkForUpdates({ manual: false });
			}, UPDATE_STARTUP_DELAY_MS);
			this.registerInterval(window.setInterval(() => void this.checkForUpdates({ manual: false }), UPDATE_CHECK_INTERVAL_MS));
			this.scheduleAutoSync();
			if (this.settings.autoSyncMinutes > 0 && this.isConfigured()) {
				// Give the metadata cache a moment to index existing notes.
				this.startupTimer = window.setTimeout(() => {
					this.startupTimer = null;
					void this.sync({ manual: false });
				}, STARTUP_SYNC_DELAY_MS);
			}
		});
	}

	onunload(): void {
		this.unloaded = true;
		this.requestSave.run();
		if (this.startupTimer !== null) window.clearTimeout(this.startupTimer);
		if (this.updateTimer !== null) window.clearTimeout(this.updateTimer);
		if (this.autoSyncTimer !== null) window.clearInterval(this.autoSyncTimer);
	}

	// -------------------------------------------------------------------------
	// Persistence

	private async loadPluginData(): Promise<void> {
		const raw = ((await this.loadData()) ?? {}) as Partial<PluginData>;
		this.settings = loadSettings(raw.settings);
		this.updateMeta = { lastCheckAt: null, notifiedVersion: null, ...(raw.update ?? {}) };
		this.syncState = { ...initialCursorState(), ...(raw.sync ?? {}) };
		this.meta = { lastSyncAt: null, lastSyncCount: 0, ...(raw.meta ?? {}) };
		this.paths = { ...(raw.paths ?? {}) };
		this.jsonRecords = { ...(raw.jsonRecords ?? {}) };
	}

	private async savePluginData(): Promise<void> {
		const data: PluginData = {
			settings: this.settings,
			update: this.updateMeta,
			sync: this.syncState,
			meta: this.meta,
			paths: this.paths,
			jsonRecords: this.jsonRecords,
		};
		await this.saveData(data);
	}

	async saveSettings(): Promise<void> {
		await this.savePluginData();
	}

	// -------------------------------------------------------------------------
	// Public actions (commands, settings tab)

	isConfigured(): boolean {
		return normalizeServerUrl(this.settings.serverUrl).length > 0 && this.settings.apiKey.length > 0;
	}

	private createClient(): LocalOcrClient {
		return new LocalOcrClient(this.settings.serverUrl, this.settings.apiKey, obsidianHttp);
	}

	scheduleAutoSync(): void {
		if (this.autoSyncTimer !== null) {
			window.clearInterval(this.autoSyncTimer);
			this.autoSyncTimer = null;
		}
		const minutes = this.settings.autoSyncMinutes;
		if (!(minutes > 0)) return;
		this.autoSyncTimer = this.registerInterval(
			window.setInterval(() => void this.sync({ manual: false }), minutes * 60_000),
		);
	}

	progressDescription(): string {
		return describeProgress(this.syncState.lastSeenUpdatedAt);
	}

	/** Clears the cursor so the next sync re-downloads everything. Notes are updated in place. */
	async resetProgress(notify = true): Promise<boolean> {
		if (this.syncing) {
			new Notice("LocalOCR：同步進行中，請稍後再重設進度");
			return false;
		}
		this.syncState = initialCursorState();
		await this.savePluginData();
		if (notify) new Notice("LocalOCR：已重設同步進度，下次同步會重新下載全部掃描");
		return true;
	}

	async testConnection(): Promise<void> {
		if (!normalizeServerUrl(this.settings.serverUrl)) {
			new Notice("LocalOCR：請先填入伺服器網址");
			return;
		}
		const client = this.createClient();
		let version = "";
		let database = "";
		try {
			const health = await client.health();
			version = health.version ? `v${health.version}` : "";
			database = health.database ?? "";
		} catch (error) {
			new Notice(`LocalOCR：無法連線到伺服器（/health）\n${describeError(error)}`, 10_000);
			return;
		}
		const serverInfo = [version, database ? `資料庫 ${database}` : ""].filter(Boolean).join("，");
		if (!this.settings.apiKey) {
			new Notice(`LocalOCR：伺服器可連線（${serverInfo || "正常"}），但尚未填入 API 金鑰`, 8_000);
			return;
		}
		try {
			const templates = await client.listTemplates();
			new Notice(
				`LocalOCR：連線成功！伺服器 ${serverInfo || "正常"}，API 金鑰有效，共 ${templates.length} 個樣板。`,
				8_000,
			);
		} catch (error) {
			new Notice(`LocalOCR：伺服器可連線，但讀取樣板失敗\n${describeError(error)}`, 10_000);
		}
	}

	// -------------------------------------------------------------------------
	// Online updates (from the LocalOCR server's mirror of the GitHub releases; GitHub as fallback; see updater.ts)

	/**
	 * Checks the LocalOCR server (or GitHub) for a newer version. Manual checks (command, settings button) install it
	 * right away; automatic checks run at most every 6 hours and install it when 自動更新 is on, otherwise notify once.
	 */
	async checkForUpdates(opts: { manual: boolean }): Promise<void> {
		if (this.updating) return;
		if (!opts.manual && !isCheckDue(this.updateMeta.lastCheckAt, Date.now())) return;
		let result: UpdateCheck;
		try {
			result = await checkForUpdate(obsidianDownload, this.manifest.version, (version) => requireApiVersion(version), {
				serverUrl: normalizeServerUrl(this.settings.serverUrl),
			});
		} catch (error) {
			if (opts.manual) new Notice(`LocalOCR：無法檢查更新\n${describeUpdateError(error)}`, 10_000);
			else console.warn(LOG_PREFIX, "檢查更新失敗：", describeUpdateError(error));
			return;
		}
		if (this.unloaded) return;
		this.lastUpdateCheck = result;
		this.updateMeta.lastCheckAt = new Date().toISOString();
		this.requestSave();

		if (result.status === "up-to-date") {
			if (opts.manual) new Notice(`LocalOCR Sync 已是最新版本（${this.manifest.version}）`);
			return;
		}
		const { version } = result.release;
		if (result.status === "needs-newer-obsidian") {
			if (opts.manual || this.updateMeta.notifiedVersion !== version) {
				new Notice(`LocalOCR Sync ${version} 需要 Obsidian ${result.minAppVersion} 以上，請先更新 Obsidian`, 10_000);
				this.updateMeta.notifiedVersion = version;
			}
			return;
		}
		if (opts.manual || this.settings.autoUpdate) {
			await this.installUpdate(result.release);
		} else if (this.updateMeta.notifiedVersion !== version) {
			new Notice(`LocalOCR Sync 有新版本 ${version}：執行「檢查並更新插件」或到插件設定按「檢查並更新」`, 10_000);
			this.updateMeta.notifiedVersion = version;
		}
	}

	/** One line for the settings tab: the latest check's outcome. */
	updateStatusText(): string {
		const check = this.lastUpdateCheck;
		const checkedAt = this.updateMeta.lastCheckAt ? `上次檢查：${formatDateTime(this.updateMeta.lastCheckAt)}。` : "";
		const from = (release: PluginRelease | null) => (release ? `（來源：${describeSource(release.source)}）` : "");
		if (check?.status === "available") return `有新版本 ${check.release.version}${from(check.release)}。${checkedAt}`;
		if (check?.status === "needs-newer-obsidian") {
			return `新版本 ${check.release.version} 需要 Obsidian ${check.minAppVersion} 以上。${checkedAt}`;
		}
		if (check?.status === "up-to-date") return `已是最新版本${from(check.latest)}。${checkedAt}`;
		return checkedAt || "從你的 Railway 伺服器檢查新版本（未填伺服器網址或伺服器沒有可用版本時改用 GitHub）。";
	}

	/** Downloads, verifies and installs a release, then reloads the plugin so the new version runs. */
	private async installUpdate(release: PluginRelease): Promise<void> {
		if (this.syncing) {
			// Never swap the code under a running sync: install when it ends.
			this.pendingUpdate = release;
			return;
		}
		if (this.updating) return;
		this.updating = true;
		try {
			await this.writePluginFiles(await downloadRelease(obsidianDownload, release));
		} catch (error) {
			this.updating = false;
			new Notice(`LocalOCR：更新到 ${release.version} 失敗，仍使用 ${this.manifest.version}\n${describeUpdateError(error)}`, 10_000);
			return;
		}
		this.updateMeta.notifiedVersion = release.version;
		await this.savePluginData();
		const notes = release.notes.split("\n").filter((line) => line.trim()).slice(0, 4).join("\n");
		new Notice(`LocalOCR Sync 已更新到 ${release.version}${notes ? `\n${notes}` : ""}`, 12_000);
		this.reloadSelf();
	}

	private pluginDir(): string {
		return normalizePath(this.manifest.dir ?? `${this.app.vault.configDir}/plugins/${this.manifest.id}`);
	}

	/** Writes the new files (main.js before manifest.json); puts the old ones back if a write fails. */
	private async writePluginFiles(files: Partial<Record<UpdateFileName, string>>): Promise<void> {
		const adapter = this.app.vault.adapter;
		const dir = this.pluginDir();
		const previous = new Map<string, string | null>();
		for (const name of UPDATE_FILES) {
			if (files[name] === undefined) continue;
			const path = `${dir}/${name}`;
			previous.set(path, (await adapter.exists(path)) ? await adapter.read(path) : null);
		}
		try {
			for (const name of UPDATE_FILES) {
				const text = files[name];
				if (text !== undefined) await adapter.write(`${dir}/${name}`, text);
			}
		} catch (error) {
			for (const [path, text] of previous) {
				if (text !== null) await adapter.write(path, text).catch(() => undefined);
			}
			throw error;
		}
	}

	/** Reloads this plugin from its folder so the new main.js runs. */
	private reloadSelf(): void {
		const plugins = (this.app as unknown as { plugins?: PluginManager }).plugins;
		const id = this.manifest.id;
		const restartNotice = () => new Notice("LocalOCR Sync：請重新啟動 Obsidian 以完成更新", 10_000);
		if (!plugins) {
			restartNotice();
			return;
		}
		window.setTimeout(() => {
			void (async () => {
				try {
					await plugins.loadManifests();
					await plugins.disablePlugin(id);
					await plugins.enablePlugin(id);
				} catch (error) {
					console.error(LOG_PREFIX, "重新載入失敗：", error);
					restartNotice();
				}
			})();
		}, 500);
	}

	/** 「配對 iPhone／iPad」: a single-use code that gives the LocalOCR app this server and API key. */
	async openPairing(): Promise<void> {
		if (!this.isConfigured()) {
			new Notice("LocalOCR：請先在設定中填入伺服器網址與 API 金鑰");
			return;
		}
		const client = this.createClient();
		const createCode = () => createPairingCode(client, this.app.vault.getName());
		try {
			new PairingModal(this.app, await createCode(), createCode).open();
		} catch (error) {
			new Notice(`LocalOCR：無法產生配對碼\n${describeSetupError(error)}`, 10_000);
		}
	}

	/** 「設定 Remotely Save（同步 vault）」: the server's bucket settings for Remotely Save, here or by QR code. */
	async openRemotelySaveSetup(): Promise<void> {
		if (!this.isConfigured()) {
			new Notice("LocalOCR：請先在設定中填入伺服器網址與 API 金鑰");
			return;
		}
		const vaultName = this.app.vault.getName();
		try {
			const setup = await fetchRemotelySaveSetup(this.createClient(), vaultName);
			new RemotelySaveModal(this.app, setup, vaultName).open();
		} catch (error) {
			new Notice(`LocalOCR：無法取得 Remotely Save 設定\n${describeSetupError(error)}`, 10_000);
		}
	}

	async sync(opts: { manual: boolean }): Promise<void> {
		if (this.syncing) {
			if (opts.manual) new Notice("LocalOCR：同步進行中，請稍候");
			return;
		}
		if (!this.isConfigured()) {
			if (opts.manual) new Notice("LocalOCR：請先在設定中填入伺服器網址與 API 金鑰");
			return;
		}
		const createNotes = this.settings.createNotes;
		const exportJson = this.hasJsonMappings();
		if (!createNotes && !exportJson) {
			// Syncing would advance the progress without writing anything.
			if (opts.manual) new Notice("LocalOCR：請開啟「同時建立筆記」或新增 JSON 陣列輸出的對應");
			return;
		}
		this.syncing = true;
		this.frontmatterIndex = null;
		this.setStatus("LocalOCR：同步中…");
		try {
			const result = await runSync({
				client: this.createClient(),
				state: this.syncState,
				writeScan: createNotes ? (scan, templates) => this.writeScan(scan, templates) : undefined,
				exportJson: exportJson ? (scan) => this.exportJson(scan) : undefined,
				saveState: async (state) => {
					this.syncState = state;
					await this.savePluginData();
				},
				isCancelled: () => this.unloaded,
				onProgress: (r) => this.setStatus(`LocalOCR：同步中…（已處理 ${r.pages} 頁）`),
			});
			if (this.unloaded) return;
			this.meta = { lastSyncAt: new Date().toISOString(), lastSyncCount: result.changed };
			await this.savePluginData();
			this.lastSyncFailed = false;
			this.renderIdleStatus();
			if (opts.manual) new Notice(`LocalOCR 同步完成：${summarize(result, { notes: createNotes })}`);
			const failed = result.failed + result.json.failed;
			if (failed > 0) {
				console.warn(LOG_PREFIX, "部分掃描無法寫入：", result.errors);
				new Notice(`LocalOCR：${failed} 筆寫入失敗\n${result.errors.join("\n")}`, 15_000);
			}
		} catch (error) {
			const message = describeError(error);
			this.setStatus("LocalOCR：同步失敗", message);
			if (opts.manual || !this.lastSyncFailed) {
				const partial = error instanceof SyncAbortedError ? error.result : null;
				const extra = partial && partial.pages > 0 ? "\n（已完成的頁面會保留，下次會從中斷處繼續）" : "";
				new Notice(`LocalOCR 同步失敗：${message}${extra}`, 10_000);
			}
			this.lastSyncFailed = true;
			console.error(LOG_PREFIX, "同步失敗：", message);
		} finally {
			this.syncing = false;
			this.frontmatterIndex = null;
			const update = this.pendingUpdate;
			this.pendingUpdate = null;
			if (update && !this.unloaded) void this.installUpdate(update);
		}
	}

	// -------------------------------------------------------------------------
	// Notes

	private async writeScan(scan: Scan, templates: ReadonlyMap<string, string>): Promise<WriteOutcome> {
		const templateName = resolveTemplateName(scan.templateId, templates);
		const opts: RenderOptions = { templateName, includeText: this.settings.includeText };

		const existing = this.findNoteFor(scan.id);
		if (existing) {
			this.paths[scan.id] = existing.path;
			const current = await this.app.vault.read(existing);
			if (mergeNote(current, scan, opts) === current) return "unchanged";
			await this.app.vault.process(existing, (data) => mergeNote(data, scan, opts));
			return "updated";
		}

		const desired = normalizePath(
			buildNotePath(scan, {
				folder: this.settings.folder,
				subfolderPerTemplate: this.settings.subfolderPerTemplate,
				templateName,
			}),
		);
		const slash = desired.lastIndexOf("/");
		if (slash > 0) await this.ensureFolder(desired.slice(0, slash));
		const path = await uniquePath(desired, (candidate) => this.pathExists(candidate));
		const file = await this.app.vault.create(path, renderNote(scan, opts));
		this.paths[scan.id] = file.path;
		return "created";
	}

	private hasJsonMappings(): boolean {
		return this.settings.jsonMappings.some((m) => m.templateId.trim() && m.filePath.trim());
	}

	private jsonOptions(): UpsertOptions {
		return {
			preserveFields: parseFieldList(this.settings.jsonPreserveFields),
			doneField: this.settings.jsonDoneField.trim(),
		};
	}

	/** Upsert the scan's `data` into the JSON array file mapped to its template. */
	private async exportJson(scan: Scan): Promise<JsonOutcome | null> {
		const mapping = findMapping(this.settings.jsonMappings, scan.templateId);
		if (!mapping) return null;
		const prepared = prepareRecord(scan);
		if (!prepared) return null; // data is not a JSON object
		const filePath = normalizePath(mapping.filePath.trim());
		const opts = this.jsonOptions();
		const ref = this.jsonRecords[scan.id];
		// Also match the id written last time (e.g. data gained its own id since).
		const altIds = ref && ref.filePath === filePath && ref.recordId !== prepared.recordId ? [ref.recordId] : [];

		let outcome: JsonOutcome;
		const existing = this.app.vault.getAbstractFileByPath(filePath);
		if (existing instanceof TFile) {
			// Dry run first so unchanged/skipped records and invalid files cause no write.
			const preview = upsertIntoJsonText(await this.app.vault.read(existing), prepared, opts, altIds, filePath);
			outcome = preview.outcome;
			if (preview.text !== null) {
				let failure: unknown = null;
				await this.app.vault.process(existing, (data) => {
					try {
						const result = upsertIntoJsonText(data, prepared, opts, altIds, filePath);
						outcome = result.outcome;
						return result.text ?? data;
					} catch (error) {
						failure = error;
						return data;
					}
				});
				if (failure) throw failure;
			}
		} else if (existing) {
			throw new Error(`「${filePath}」是資料夾，無法寫入 JSON`);
		} else {
			const slash = filePath.lastIndexOf("/");
			if (slash > 0) await this.ensureFolder(filePath.slice(0, slash));
			if (await this.app.vault.adapter.exists(filePath)) {
				throw new Error(`「${filePath}」已存在但無法在保險庫中讀取，已略過，不會覆寫`);
			}
			const created = upsertIntoJsonText(null, prepared, opts);
			await this.app.vault.create(filePath, created.text ?? "[]\n");
			outcome = created.outcome;
		}
		this.jsonRecords[scan.id] = { filePath, recordId: prepared.recordId };
		return outcome;
	}

	/** The note previously written for this scan, if it still exists. */
	private findNoteFor(scanId: string): TFile | null {
		const mapped = this.paths[scanId];
		if (mapped) {
			const file = this.app.vault.getAbstractFileByPath(mapped);
			if (file instanceof TFile) return file;
		}
		// Fallback for lost plugin data or notes moved while Obsidian was closed.
		const indexed = this.getFrontmatterIndex().get(scanId);
		if (indexed && this.app.vault.getAbstractFileByPath(indexed.path) === indexed) return indexed;
		return null;
	}

	private getFrontmatterIndex(): Map<string, TFile> {
		if (!this.frontmatterIndex) {
			const index = new Map<string, TFile>();
			for (const file of this.app.vault.getMarkdownFiles()) {
				const id: unknown = this.app.metadataCache.getFileCache(file)?.frontmatter?.localocr_id;
				if (typeof id === "string" && id && !index.has(id)) index.set(id, file);
			}
			this.frontmatterIndex = index;
		}
		return this.frontmatterIndex;
	}

	private async pathExists(path: string): Promise<boolean> {
		if (this.app.vault.getAbstractFileByPath(path)) return true;
		// Catches case-only collisions on case-insensitive file systems.
		return this.app.vault.adapter.exists(path);
	}

	private async ensureFolder(folder: string): Promise<void> {
		let current = "";
		for (const part of folder.split("/")) {
			current = current ? `${current}/${part}` : part;
			const existing = this.app.vault.getAbstractFileByPath(current);
			if (existing instanceof TFolder) continue;
			if (existing) throw new Error(`「${current}」已存在且不是資料夾`);
			try {
				await this.app.vault.createFolder(current);
			} catch (error) {
				if (!(this.app.vault.getAbstractFileByPath(current) instanceof TFolder)) throw error;
			}
		}
	}

	private onFileRenamed(file: TAbstractFile, oldPath: string): void {
		let changed = false;
		const prefix = `${oldPath}/`;
		for (const [id, path] of Object.entries(this.paths)) {
			if (path === oldPath) {
				this.paths[id] = file.path;
				changed = true;
			} else if (file instanceof TFolder && path.startsWith(prefix)) {
				this.paths[id] = `${file.path}/${path.slice(prefix.length)}`;
				changed = true;
			}
		}
		for (const ref of Object.values(this.jsonRecords)) {
			if (ref.filePath === oldPath) {
				ref.filePath = file.path;
				changed = true;
			} else if (file instanceof TFolder && ref.filePath.startsWith(prefix)) {
				ref.filePath = `${file.path}/${ref.filePath.slice(prefix.length)}`;
				changed = true;
			}
		}
		if (changed) this.requestSave();
	}

	private onFileDeleted(file: TAbstractFile): void {
		let changed = false;
		const prefix = `${file.path}/`;
		for (const [id, path] of Object.entries(this.paths)) {
			if (path === file.path || path.startsWith(prefix)) {
				delete this.paths[id];
				changed = true;
			}
		}
		if (changed) this.requestSave();
	}

	// -------------------------------------------------------------------------
	// Status bar

	private setStatus(text: string, tooltip?: string): void {
		if (!this.statusBarEl) return;
		this.statusBarEl.setText(text);
		this.statusBarEl.setAttr("aria-label", tooltip ?? "點一下立即同步 LocalOCR");
		this.statusBarEl.setAttr("data-tooltip-position", "top");
	}

	private renderIdleStatus(): void {
		const { lastSyncAt, lastSyncCount } = this.meta;
		if (lastSyncAt) {
			const date = new Date(lastSyncAt);
			this.setStatus(
				`LocalOCR：${formatClock(date)} 已同步 ${lastSyncCount} 筆`,
				`上次同步：${formatDateTime(lastSyncAt)}（點一下立即同步）`,
			);
		} else {
			this.setStatus("LocalOCR：尚未同步");
		}
	}
}
