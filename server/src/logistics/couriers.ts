// Couriers and statuses of the logistics tracker (ported from the vault's 物流追蹤中心 dataviewjs tool, 99 工具/物流追蹤.md,
// and its scripts/logistics_tracker.py). Codes and status ids are the ones in 06 日誌/物流追蹤/watchlist.json, so the
// desktop tool keeps working on the same file.

/** How the server reads a courier's progress. */
export type TrackSource = "tcat" | "sf" | "dhl" | "17track";

export interface Courier {
  code: string;
  name: string;
  source: TrackSource;
  /** The courier's own tracking page; `{number}` is replaced by the URL-encoded tracking number. */
  url: string;
}

export const COURIERS: readonly Courier[] = [
  { code: "t-cat", name: "黑貓宅急便", source: "tcat", url: "https://www.t-cat.com.tw/Inquire/Trace.aspx?BillID={number}" },
  { code: "dhl", name: "DHL Express", source: "dhl", url: "https://www.dhl.com/tw-zh/home/tracking/tracking-express.html?submit=1&tracking-id={number}" },
  { code: "fedex", name: "FedEx 聯邦快遞", source: "17track", url: "https://www.fedex.com/fedextrack/?trknbr={number}" },
  { code: "ups", name: "UPS 優比速", source: "17track", url: "https://www.ups.com/track?tracknum={number}&loc=zh_TW" },
  {
    code: "sf-express",
    name: "順豐速運",
    source: "sf",
    url: "https://www.sf-express.com/tw/tc/dynamic_function/waybill/waybill_query_by_bill_no.html?billNo={number}",
  },
  { code: "tw-hct-logistics", name: "新竹物流", source: "17track", url: "https://www.hct.com.tw/searchgoods.aspx" },
  { code: "kerry-tj", name: "嘉里大榮", source: "17track", url: "https://www.kerrytj.com/ZH/search/search_sort.aspx" },
  { code: "taiwan-post", name: "中華郵政", source: "17track", url: "https://postserv.post.gov.tw/pstmail/main_mail.html" },
];

export interface StatusInfo {
  id: string;
  label: string;
  /** Hex color of the status chip (the tool's colors). */
  color: string;
}

/** The tool's five statuses, plus "notfound" (the T-Cat parser's "no record yet"; the tool shows it as the first). */
export const STATUSES: readonly StatusInfo[] = [
  { id: "transit", label: "運送中", color: "#2563eb" },
  { id: "delivered", label: "已送達", color: "#059669" },
  { id: "pickup", label: "已攬收", color: "#d97706" },
  { id: "exception", label: "異常", color: "#dc2626" },
  { id: "pending", label: "待處理", color: "#7c3aed" },
  { id: "notfound", label: "查無資料", color: "#6b7280" },
];

export const STATUS_IDS = STATUSES.map((status) => status.id) as [string, ...string[]];

export function courierFor(code: string): Courier | undefined {
  return COURIERS.find((courier) => courier.code === code.toLowerCase());
}

/** The tool's names; an unknown code is shown upper-cased (like the Python script). */
export function courierName(code: string): string {
  return courierFor(code)?.name ?? code.toUpperCase();
}

export function trackingUrl(code: string, number: string): string {
  const courier = courierFor(code);
  return courier ? courier.url.replace("{number}", encodeURIComponent(number)) : track17Url(number);
}

export function track17Url(number: string): string {
  return `https://t.17track.net/zh-tw#nums=${encodeURIComponent(number)}`;
}

/**
 * A guess from the number's shape (for notes that name no courier): SF + digits = 順豐, 1Z… = UPS, 10 digits = DHL,
 * 12 digits starting with 9 = 黑貓, other 12 or 15 digits = FedEx. null when nothing fits.
 */
export function guessCourier(number: string): string | null {
  const value = number.trim().toUpperCase();
  if (/^SF\d{10,15}$/.test(value)) return "sf-express";
  if (/^1Z[0-9A-Z]{16}$/.test(value)) return "ups";
  if (/^\d{10}$/.test(value)) return "dhl";
  if (/^9\d{11}$/.test(value)) return "t-cat";
  if (/^\d{12}$|^\d{15}$/.test(value)) return "fedex";
  return null;
}
