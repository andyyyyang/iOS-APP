import { App, Modal, Notice } from "obsidian";
import QRCode from "qrcode";
import {
	REMOTELY_SAVE_PLUGIN_ID,
	describeSetupError,
	formatCountdown,
	isPluginEnabled,
	remainingMs,
	type PairingCode,
	type RemotelySaveSetup,
} from "./device-setup";

/** QR code as a PNG data URL. Level L keeps the long Remotely Save URI scannable on a screen. */
function qrDataUrl(text: string): Promise<string> {
	return QRCode.toDataURL(text, { errorCorrectionLevel: "L", margin: 2, width: 560 });
}

function renderQr(parent: HTMLElement, text: string): HTMLImageElement {
	const img = parent.createEl("img", { attr: { alt: "QR Code" } });
	img.setCssStyles({
		display: "block",
		margin: "12px auto",
		width: "280px",
		maxWidth: "100%",
		imageRendering: "pixelated",
		background: "#fff",
	});
	qrDataUrl(text).then(
		(url) => (img.src = url),
		(error: unknown) => {
			img.remove();
			parent.createEl("p", { text: `無法產生 QR Code：${describeSetupError(error)}`, cls: "mod-warning" });
		},
	);
	return img;
}

/** 「配對 iPhone／iPad」: QR code of the pairing link, the code itself and a live countdown. */
export class PairingModal extends Modal {
	private timer: number | null = null;

	constructor(
		app: App,
		private pairing: PairingCode,
		private readonly createCode: () => Promise<PairingCode>,
	) {
		super(app);
	}

	onOpen(): void {
		this.titleEl.setText("配對 iPhone／iPad");
		this.render();
	}

	onClose(): void {
		this.stopTimer();
		this.contentEl.empty();
	}

	private stopTimer(): void {
		if (this.timer !== null) window.clearInterval(this.timer);
		this.timer = null;
	}

	private render(): void {
		this.stopTimer();
		const { contentEl } = this;
		contentEl.empty();

		contentEl.createEl("p", {
			text: "在 iPhone／iPad 的 LocalOCR App 開啟『設定 → 配對』掃描 QR Code，或輸入配對碼",
		});
		const qr = renderQr(contentEl, this.pairing.pairUrl);

		const code = contentEl.createDiv({ text: this.pairing.code });
		code.setCssStyles({
			fontFamily: "var(--font-monospace)",
			fontSize: "2.4em",
			fontWeight: "bold",
			letterSpacing: "0.12em",
			textAlign: "center",
			userSelect: "all",
		});

		const countdown = contentEl.createDiv();
		countdown.setCssStyles({ textAlign: "center", color: "var(--text-muted)", margin: "4px 0 12px" });
		const tick = () => {
			const left = remainingMs(this.pairing.expiresAt, Date.now());
			if (left > 0) {
				countdown.setText(`剩餘 ${formatCountdown(left)}（只能使用一次）`);
				return;
			}
			countdown.setText("配對碼已過期，請產生新的配對碼");
			countdown.setCssStyles({ color: "var(--text-error)" });
			qr.setCssStyles({ opacity: "0.25" });
			code.setCssStyles({ opacity: "0.4", textDecoration: "line-through" });
			this.stopTimer();
		};
		tick();
		if (remainingMs(this.pairing.expiresAt, Date.now()) > 0) this.timer = window.setInterval(tick, 1000);

		contentEl.createEl("p", {
			text: "配對後，App 會取得伺服器網址與這台裝置使用的 API 金鑰，並同步整個保險庫（所有資料夾的筆記與檔案）。",
			cls: "setting-item-description",
		});

		const buttons = contentEl.createDiv({ cls: "modal-button-container" });
		const again = buttons.createEl("button", { text: "產生新的配對碼" });
		again.addEventListener("click", async () => {
			again.disabled = true;
			try {
				this.pairing = await this.createCode();
				this.render();
			} catch (error) {
				new Notice(`LocalOCR：無法產生配對碼\n${describeSetupError(error)}`, 10_000);
				again.disabled = false;
			}
		});
		buttons.createEl("button", { text: "關閉", cls: "mod-cta" }).addEventListener("click", () => this.close());
	}
}

/** 「設定 Remotely Save（同步 vault）」: apply here with one tap, or scan the QR code on iPhone／iPad. */
export class RemotelySaveModal extends Modal {
	constructor(
		app: App,
		private readonly setup: RemotelySaveSetup,
		private readonly vaultName: string,
	) {
		super(app);
	}

	onOpen(): void {
		this.titleEl.setText("設定 Remotely Save（同步 vault）");
		const { contentEl } = this;
		contentEl.empty();

		contentEl.createEl("h4", { text: "這台裝置" });
		contentEl.createEl("p", {
			text:
				"把伺服器的儲存桶設定套用到這台裝置的 Remotely Save：S3 連線、啟動 10 秒後同步一次、每 5 分鐘自動同步、儲存時同步。" +
				"Remotely Save 的其他設定（例如加密密碼，請保持空白）不會變更。",
		});
		if (isPluginEnabled(this.app, REMOTELY_SAVE_PLUGIN_ID) === false) {
			contentEl.createEl("p", {
				text: "這台裝置尚未安裝或啟用 Remotely Save：請先到「設定 → 第三方外掛」安裝並啟用，再按「套用到這台裝置」。",
				cls: "mod-warning",
			});
		}
		const buttons = contentEl.createDiv({ cls: "modal-button-container" });
		buttons.createEl("button", { text: "套用到這台裝置", cls: "mod-cta" }).addEventListener("click", () => this.apply());

		contentEl.createEl("h4", { text: "iPhone／iPad" });
		contentEl.createEl("p", {
			text: "在 iPhone／iPad 用相機掃描，即可在那台裝置的 Obsidian 套用同樣設定（需先安裝 Remotely Save）",
		});
		contentEl.createEl("p", {
			text: `那台裝置的保險庫名稱必須也是「${this.vaultName}」，否則 Remotely Save 會拒絕套用。`,
			cls: "setting-item-description",
		});
		renderQr(contentEl, this.setup.uri);
		contentEl.createEl("p", {
			text: "注意：這個 QR Code 含有儲存桶的存取金鑰，請勿截圖或分享給他人。",
			cls: "mod-warning",
		});
	}

	onClose(): void {
		this.contentEl.empty();
	}

	private apply(): void {
		// Checked again on click: the plugin may have been enabled while this dialog was open.
		if (isPluginEnabled(this.app, REMOTELY_SAVE_PLUGIN_ID) === false) {
			new Notice("LocalOCR：請先安裝並啟用 Remotely Save（設定 → 第三方外掛），再套用設定", 10_000);
			return;
		}
		// Obsidian routes obsidian://remotely-save to Remotely Save's own settings import.
		window.open(this.setup.uri);
		new Notice(
			"LocalOCR：已把設定交給 Remotely Save。看到 Remotely Save 的「已匯入」通知後，請重新啟動 Obsidian，自動同步才會開始。",
			15_000,
		);
		this.close();
	}
}
