import { App, PluginSettingTab, Setting } from "obsidian";
import type LocalOcrSyncPlugin from "./main";
import { formatDateTime } from "./format";
import type { JsonMapping } from "./json-export";

export interface LocalOcrSettings {
	serverUrl: string;
	apiKey: string;
	folder: string;
	subfolderPerTemplate: boolean;
	/** Minutes between automatic syncs; 0 disables auto-sync. */
	autoSyncMinutes: number;
	includeText: boolean;
	/** Create Markdown notes (turn off for JSON-only output). */
	createNotes: boolean;
	/** Template id → JSON array file. */
	jsonMappings: JsonMapping[];
	/** Comma-separated fields whose existing values survive updates. */
	jsonPreserveFields: string;
	/** Field that marks a JSON record as finished (never touched again). */
	jsonDoneField: string;
}

export const DEFAULT_SETTINGS: LocalOcrSettings = {
	serverUrl: "",
	apiKey: "",
	folder: "LocalOCR",
	subfolderPerTemplate: true,
	autoSyncMinutes: 15,
	includeText: true,
	createNotes: true,
	jsonMappings: [],
	jsonPreserveFields: "docNo, done",
	jsonDoneField: "done",
};

/** Merge saved settings over the defaults (never sharing the defaults' arrays). */
export function loadSettings(saved: Partial<LocalOcrSettings> | undefined): LocalOcrSettings {
	const settings: LocalOcrSettings = { ...DEFAULT_SETTINGS, ...(saved ?? {}) };
	if (typeof settings.autoSyncMinutes !== "number" || !(settings.autoSyncMinutes >= 0)) {
		settings.autoSyncMinutes = DEFAULT_SETTINGS.autoSyncMinutes;
	}
	settings.jsonMappings = Array.isArray(saved?.jsonMappings)
		? saved.jsonMappings.map((m) => ({
				templateId: typeof m?.templateId === "string" ? m.templateId : "",
				filePath: typeof m?.filePath === "string" ? m.filePath : "",
			}))
		: [];
	if (typeof settings.jsonPreserveFields !== "string") settings.jsonPreserveFields = DEFAULT_SETTINGS.jsonPreserveFields;
	if (typeof settings.jsonDoneField !== "string") settings.jsonDoneField = DEFAULT_SETTINGS.jsonDoneField;
	return settings;
}

export class LocalOcrSettingTab extends PluginSettingTab {
	constructor(
		app: App,
		private readonly plugin: LocalOcrSyncPlugin,
	) {
		super(app, plugin);
	}

	display(): void {
		const { containerEl } = this;
		containerEl.empty();
		const settings = this.plugin.settings;

		new Setting(containerEl).setName("連線").setHeading();

		new Setting(containerEl)
			.setName("伺服器網址")
			.setDesc("LocalOCR 伺服器的網址，例如 https://xxx.up.railway.app（結尾不需要斜線）。")
			.addText((text) =>
				text
					.setPlaceholder("https://xxx.up.railway.app")
					.setValue(settings.serverUrl)
					.onChange(async (value) => {
						settings.serverUrl = value.trim().replace(/\/+$/, "");
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("API 金鑰")
			.setDesc("伺服器環境變數 API_KEYS 中的其中一把金鑰。金鑰會儲存在此保險庫的插件資料中。")
			.addText((text) => {
				text.inputEl.type = "password";
				text.inputEl.autocomplete = "off";
				text
					.setPlaceholder("API 金鑰")
					.setValue(settings.apiKey)
					.onChange(async (value) => {
						settings.apiKey = value.trim();
						await this.plugin.saveSettings();
					});
			});

		new Setting(containerEl)
			.setName("測試連線")
			.setDesc("檢查伺服器 /health，並以 API 金鑰讀取樣板清單。")
			.addButton((button) =>
				button.setButtonText("測試連線").onClick(async () => {
					button.setDisabled(true);
					try {
						await this.plugin.testConnection();
					} finally {
						button.setDisabled(false);
					}
				}),
			);

		new Setting(containerEl).setName("筆記").setHeading();

		new Setting(containerEl)
			.setName("同時建立筆記")
			.setDesc("每筆掃描建立一則 Markdown 筆記。關閉時只寫入下方設定的 JSON 陣列檔。")
			.addToggle((toggle) =>
				toggle.setValue(settings.createNotes).onChange(async (value) => {
					settings.createNotes = value;
					await this.plugin.saveSettings();
				}),
			);

		new Setting(containerEl)
			.setName("目標資料夾")
			.setDesc("同步的筆記會放在這個資料夾（相對於保險庫根目錄）。")
			.addText((text) =>
				text
					.setPlaceholder(DEFAULT_SETTINGS.folder)
					.setValue(settings.folder)
					.onChange(async (value) => {
						settings.folder = value.trim();
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("依樣板建立子資料夾")
			.setDesc("開啟時，筆記會依樣板名稱分到子資料夾（沒有樣板的放在「未分類」）。")
			.addToggle((toggle) =>
				toggle.setValue(settings.subfolderPerTemplate).onChange(async (value) => {
					settings.subfolderPerTemplate = value;
					await this.plugin.saveSettings();
				}),
			);

		new Setting(containerEl)
			.setName("包含辨識文字")
			.setDesc("在筆記中加入「辨識文字」段落（OCR 全文）。")
			.addToggle((toggle) =>
				toggle.setValue(settings.includeText).onChange(async (value) => {
					settings.includeText = value;
					await this.plugin.saveSettings();
				}),
			);

		this.displayJsonSection(containerEl);

		new Setting(containerEl).setName("同步").setHeading();

		new Setting(containerEl)
			.setName("自動同步間隔（分鐘）")
			.setDesc("每隔幾分鐘自動同步一次；設為 0 表示關閉自動同步。")
			.addText((text) => {
				text.inputEl.type = "number";
				text.inputEl.min = "0";
				text
					.setPlaceholder(String(DEFAULT_SETTINGS.autoSyncMinutes))
					.setValue(String(settings.autoSyncMinutes))
					.onChange(async (value) => {
						const minutes = Number.parseInt(value, 10);
						if (!Number.isFinite(minutes) || minutes < 0) return;
						settings.autoSyncMinutes = minutes;
						await this.plugin.saveSettings();
						this.plugin.scheduleAutoSync();
					});
			});

		const progress = this.plugin.progressDescription();
		new Setting(containerEl)
			.setName("重設同步進度")
			.setDesc(
				`下次同步時重新下載全部掃描；已存在的筆記與 JSON 紀錄會原地更新，不會重複建立。${progress ? `目前進度：${progress}` : ""}`,
			)
			.addButton((button) =>
				button
					.setButtonText("重設同步進度")
					.setWarning()
					.onClick(async () => {
						await this.plugin.resetProgress();
						this.display();
					}),
			);
	}

	private displayJsonSection(containerEl: HTMLElement): void {
		const settings = this.plugin.settings;
		new Setting(containerEl)
			.setName("JSON 陣列輸出")
			.setDesc(
				"把指定情境（樣板）掃描的結構化資料，依 id 新增或更新到保險庫中的 JSON 陣列檔（最新的在最前面）。" +
					"新增對應後，執行「重新同步全部（重設進度）」即可補上先前的掃描。",
			)
			.setHeading();

		settings.jsonMappings.forEach((mapping, index) => {
			new Setting(containerEl)
				.setName(`對應 ${index + 1}`)
				.setDesc("情境代碼 → JSON 檔案路徑")
				.addText((text) => {
					text.inputEl.setAttr("aria-label", "情境代碼");
					text
						.setPlaceholder("情境代碼，例如 fv60_air")
						.setValue(mapping.templateId)
						.onChange(async (value) => {
							mapping.templateId = value.trim();
							await this.plugin.saveSettings();
						});
				})
				.addText((text) => {
					text.inputEl.setAttr("aria-label", "JSON 檔案路徑");
					text
						.setPlaceholder("JSON 檔案路徑，例如 11 SOP/紀錄.json")
						.setValue(mapping.filePath)
						.onChange(async (value) => {
							mapping.filePath = value.trim();
							await this.plugin.saveSettings();
						});
				})
				.addExtraButton((button) =>
					button
						.setIcon("trash-2")
						.setTooltip("移除這個對應")
						.onClick(async () => {
							settings.jsonMappings.splice(index, 1);
							await this.plugin.saveSettings();
							this.display();
						}),
				);
		});

		new Setting(containerEl).addButton((button) =>
			button
				.setButtonText("新增對應")
				.setCta()
				.onClick(async () => {
					settings.jsonMappings.push({ templateId: "", filePath: "" });
					await this.plugin.saveSettings();
					this.display();
				}),
		);

		new Setting(containerEl)
			.setName("更新時保留的欄位")
			.setDesc("以逗號分隔。更新既有紀錄時，這些欄位維持 JSON 檔中的現有值（例如你之後填入的傳票號碼）。")
			.addText((text) =>
				text
					.setPlaceholder(DEFAULT_SETTINGS.jsonPreserveFields)
					.setValue(settings.jsonPreserveFields)
					.onChange(async (value) => {
						settings.jsonPreserveFields = value;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("已完成欄位")
			.setDesc("紀錄中這個欄位為真（例如 done: true）時，同步不會再修改該筆紀錄。留空表示不檢查。")
			.addText((text) =>
				text
					.setPlaceholder(DEFAULT_SETTINGS.jsonDoneField)
					.setValue(settings.jsonDoneField)
					.onChange(async (value) => {
						settings.jsonDoneField = value.trim();
						await this.plugin.saveSettings();
					}),
			);
	}
}

/** Short description of saved progress for the settings tab. */
export function describeProgress(lastSeenUpdatedAt: string | null): string {
	return lastSeenUpdatedAt ? `已同步到 ${formatDateTime(lastSeenUpdatedAt)} 更新的掃描。` : "";
}
