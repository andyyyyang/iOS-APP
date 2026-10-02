import { App, PluginSettingTab, Setting } from "obsidian";
import type LocalOcrSyncPlugin from "./main";
import { formatDateTime } from "./format";

export interface LocalOcrSettings {
	serverUrl: string;
	apiKey: string;
	folder: string;
	subfolderPerTemplate: boolean;
	/** Minutes between automatic syncs; 0 disables auto-sync. */
	autoSyncMinutes: number;
	includeText: boolean;
}

export const DEFAULT_SETTINGS: LocalOcrSettings = {
	serverUrl: "",
	apiKey: "",
	folder: "LocalOCR",
	subfolderPerTemplate: true,
	autoSyncMinutes: 15,
	includeText: true,
};

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
				`下次同步時重新下載全部掃描；已存在的筆記會原地更新，不會重複建立。${progress ? `目前進度：${progress}` : ""}`,
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
}

/** Short description of saved progress for the settings tab. */
export function describeProgress(lastSeenUpdatedAt: string | null): string {
	return lastSeenUpdatedAt ? `已同步到 ${formatDateTime(lastSeenUpdatedAt)} 更新的掃描。` : "";
}
