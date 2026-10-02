import type { TemplateWrite } from "../store/types.js";

/**
 * Built-in scenarios, seeded at startup only when missing (user edits are never overwritten).
 * Key order inside `sample` is significant: it is the output field order.
 */
export const BUILTIN_TEMPLATES: readonly TemplateWrite[] = [
  {
    id: "receipt",
    name: "收據／發票",
    description: "購物收據、統一發票、消費明細，含商店、日期、品項與金額",
    keywords: ["合計", "總計", "小計", "統一編號", "發票", "收據", "找零", "交易明細", "金額"],
    sample: {
      store: "全聯福利中心",
      date: "2026-10-02",
      time: "14:30",
      items: [{ name: "鮮乳", quantity: 1, price: 45 }],
      subtotal: 45,
      tax: 0,
      total: 45,
      currency: "TWD",
      paymentMethod: "現金",
      invoiceNumber: "AB-12345678",
    },
    instructions: "金額使用數字；日期使用 YYYY-MM-DD；時間使用 24 小時制 HH:mm；找不到的欄位填 null。",
    rules: [],
  },
  {
    id: "business_card",
    name: "名片",
    description: "個人或公司名片，含姓名、職稱、公司與聯絡方式",
    keywords: ["電話", "手機", "Tel", "Mobile", "E-mail", "Email", "傳真", "Fax", "經理", "總監", "有限公司", "股份有限公司"],
    sample: {
      name: "王小明",
      title: "產品經理",
      company: "範例科技股份有限公司",
      phones: ["02-1234-5678"],
      email: "ming@example.com",
      website: "https://example.com",
      address: "台北市信義區市府路1號",
      social: [{ platform: "LINE", handle: "ming" }],
    },
    instructions: "電話保留原始格式；找不到的欄位填 null，陣列可為空。",
    rules: [],
  },
  {
    id: "event",
    name: "活動／海報",
    description: "活動、展覽、演出或課程的海報與傳單，含名稱、時間與地點",
    keywords: ["活動", "報名", "票價", "入場", "展覽", "演出", "講座", "地點", "時間", "主辦"],
    sample: {
      title: "秋季音樂節",
      date: "2026-10-18",
      startTime: "18:00",
      endTime: "21:30",
      location: "華山1914文化創意產業園區",
      organizer: "範例文化",
      price: "免費",
      description: "戶外音樂演出",
      url: "https://example.com/event",
    },
    instructions: "日期使用 YYYY-MM-DD；時間使用 24 小時制 HH:mm；找不到的欄位填 null。",
    rules: [],
  },
  {
    id: "document",
    name: "一般文件",
    description: "其他文件、筆記、公告、信件或會議紀錄；無法歸類時使用",
    keywords: ["會議", "紀錄", "公告", "通知", "說明", "摘要"],
    sample: {
      title: "會議紀錄",
      date: "2026-10-02",
      summary: "討論第四季產品規劃",
      keyPoints: ["確認上線時程"],
      people: ["王小明"],
      actionItems: [{ task: "整理需求文件", owner: "王小明", due: "2026-10-09" }],
    },
    instructions: "摘要不超過 100 字；找不到的欄位填 null，陣列可為空。",
    rules: [],
  },
];
