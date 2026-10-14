// Wall-clock times in the user's IANA time zone (transcript headings, today's date in the system prompt).

export const DEFAULT_TIME_ZONE = "Asia/Taipei";

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

interface ZonedParts {
  year: string;
  month: string;
  day: string;
  hour: string;
  minute: string;
  second: string;
}

function zonedParts(date: Date, timeZone: string): ZonedParts {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const get = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value ?? "00";
  return { year: get("year"), month: get("month"), day: get("day"), hour: get("hour"), minute: get("minute"), second: get("second") };
}

/** "2026-10-14" */
export function zonedDate(date: Date, timeZone: string): string {
  const { year, month, day } = zonedParts(date, timeZone);
  return `${year}-${month}-${day}`;
}

/** "2026-10-14 20:05" */
export function zonedMinute(date: Date, timeZone: string): string {
  const { hour, minute } = zonedParts(date, timeZone);
  return `${zonedDate(date, timeZone)} ${hour}:${minute}`;
}

/** "2026-10-14T20:05:03+08:00" */
export function zonedIso(date: Date, timeZone: string): string {
  const { year, month, day, hour, minute, second } = zonedParts(date, timeZone);
  const wall = Date.UTC(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second));
  const offset = Math.round((wall - Math.floor(date.getTime() / 1000) * 1000) / 60_000);
  const sign = offset < 0 ? "-" : "+";
  const pad = (value: number) => String(value).padStart(2, "0");
  const abs = Math.abs(offset);
  return `${year}-${month}-${day}T${hour}:${minute}:${second}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

/** 星期 of the date in the zone: "三". */
export function zonedWeekday(date: Date, timeZone: string): string {
  const { year, month, day } = zonedParts(date, timeZone);
  return "日一二三四五六"[new Date(Date.UTC(Number(year), Number(month) - 1, Number(day))).getUTCDay()]!;
}
