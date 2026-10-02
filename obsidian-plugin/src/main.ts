import { Notice, Plugin, TAbstractFile, TFile, TFolder, debounce, normalizePath, requestUrl } from "obsidian";
import { DEFAULT_SETTINGS, LocalOcrSettingTab, describeProgress, type LocalOcrSettings } from "./settings";
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

interface SyncMeta {
	lastSyncAt: string | null;
	lastSyncCount: number;
}

interface PluginData {
	settings: LocalOcrSettings;
	sync: SyncCursorState;
	meta: SyncMeta;
	/** scan id → vault path of its note */
	paths: Record<string, string>;
}

const LOG_PREFIX = "[LocalOCR Sync]";
const STARTUP_SYNC_DELAY_MS = 5_000;

/** HTTP transport over Obsidian's requestUrl (no CORS, works on mobile). */
const obsidianHttp: HttpFn = async (request) => {
	const response = await requestUrl({
		url: request.url,
		method: request.method,
		headers: request.headers,
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

		this.registerEvent(this.app.vault.on("rename", (file, oldPath) => this.onFileRenamed(file, oldPath)));
		this.registerEvent(this.app.vault.on("delete", (file) => this.onFileDeleted(file)));

		this.app.workspace.onLayoutReady(() => {
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
		if (this.autoSyncTimer !== null) window.clearInterval(this.autoSyncTimer);
	}

	// -------------------------------------------------------------------------
	// Persistence

	private async loadPluginData(): Promise<void> {
		const raw = ((await this.loadData()) ?? {}) as Partial<PluginData>;
		this.settings = { ...DEFAULT_SETTINGS, ...(raw.settings ?? {}) };
		if (typeof this.settings.autoSyncMinutes !== "number" || !(this.settings.autoSyncMinutes >= 0)) {
			this.settings.autoSyncMinutes = DEFAULT_SETTINGS.autoSyncMinutes;
		}
		this.syncState = { ...initialCursorState(), ...(raw.sync ?? {}) };
		this.meta = { lastSyncAt: null, lastSyncCount: 0, ...(raw.meta ?? {}) };
		this.paths = { ...(raw.paths ?? {}) };
	}

	private async savePluginData(): Promise<void> {
		const data: PluginData = {
			settings: this.settings,
			sync: this.syncState,
			meta: this.meta,
			paths: this.paths,
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

	async sync(opts: { manual: boolean }): Promise<void> {
		if (this.syncing) {
			if (opts.manual) new Notice("LocalOCR：同步進行中，請稍候");
			return;
		}
		if (!this.isConfigured()) {
			if (opts.manual) new Notice("LocalOCR：請先在設定中填入伺服器網址與 API 金鑰");
			return;
		}
		this.syncing = true;
		this.frontmatterIndex = null;
		this.setStatus("LocalOCR：同步中…");
		try {
			const result = await runSync({
				client: this.createClient(),
				state: this.syncState,
				writeScan: (scan, templates) => this.writeScan(scan, templates),
				saveState: async (state) => {
					this.syncState = state;
					await this.savePluginData();
				},
				isCancelled: () => this.unloaded,
				onProgress: (r) => this.setStatus(`LocalOCR：同步中…（${r.created + r.updated + r.unchanged} 筆）`),
			});
			if (this.unloaded) return;
			this.meta = { lastSyncAt: new Date().toISOString(), lastSyncCount: result.created + result.updated };
			await this.savePluginData();
			this.lastSyncFailed = false;
			this.renderIdleStatus();
			if (opts.manual) new Notice(`LocalOCR 同步完成：${summarize(result)}`);
			if (result.failed > 0) {
				console.warn(LOG_PREFIX, "部分掃描無法寫入：", result.errors);
				new Notice(`LocalOCR：${result.failed} 筆掃描無法寫入\n${result.errors.join("\n")}`, 15_000);
			}
		} catch (error) {
			const message = describeError(error);
			this.setStatus("LocalOCR：同步失敗", message);
			if (opts.manual || !this.lastSyncFailed) {
				const partial = error instanceof SyncAbortedError ? error.result : null;
				const done = partial ? partial.created + partial.updated + partial.unchanged : 0;
				const extra = done > 0 ? `\n（已處理 ${done} 筆，下次會從中斷處繼續）` : "";
				new Notice(`LocalOCR 同步失敗：${message}${extra}`, 10_000);
			}
			this.lastSyncFailed = true;
			console.error(LOG_PREFIX, "同步失敗：", message);
		} finally {
			this.syncing = false;
			this.frontmatterIndex = null;
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
