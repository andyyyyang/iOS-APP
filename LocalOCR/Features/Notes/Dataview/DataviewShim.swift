import Foundation

// MARK: - DataviewJS 的執行環境（網頁端）
//
// 在 WKWebView 中模擬 Obsidian 與 Dataview 外掛常用的 API，讓筆記裡的 ```dataviewjs 區塊可以照原樣執行：
// - dv：el、header、paragraph、span、list、taskList、table、pages、page、current、array、fileLink、date、io.load、io.csv、view…
// - app：vault.adapter（read、write、exists、list、readBinary、getResourcePath）、vault、workspace.openLinkText、metadataCache
// - Obsidian 加在 HTMLElement 上的 createEl、createDiv、empty、addClass…；moment、Notice
// 檔案透過 App 讀寫（`vault` 訊息與 localocr-vault:// 網址），頁面清單來自伺服器的 vault 索引。

enum DataviewShim {
    /// 網頁的 base URL；同一個 scheme 的檔案網址（圖片、PDF）才能直接載入。
    static let scheme = "localocr-vault"
    static let baseURL = URL(string: "\(scheme)://app/")!

    /// 完整的網頁：樣式、執行環境與要執行的程式碼。
    static func html(code: String, sourcePath: String, vaultName: String) -> String {
        let payload: [String: Any] = ["code": code, "source": sourcePath, "vault": vaultName]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        // 程式碼裡的 </script> 不能結束這個 <script>
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>\(css)</style>
        </head><body>
        <div id="dv-root" class="block-language-dataviewjs"></div>
        <script>window.__dv = \(json);</script>
        <script>\(script)</script>
        </body></html>
        """
    }

    static let css = ##"""
    :root {
      color-scheme: light dark;
      --background-primary: #ffffff; --background-primary-alt: #f7f7f9;
      --background-secondary: #f0f0f3; --background-secondary-alt: #e8e8ec;
      --background-modifier-border: #e3e3e8; --background-modifier-border-hover: #d4d4da;
      --background-modifier-hover: rgba(0,0,0,0.05); --background-modifier-active-hover: rgba(61,91,217,0.12);
      --background-modifier-form-field: #ffffff; --background-modifier-success: #2f9e62; --background-modifier-error: #d83a3a;
      --text-normal: #16161a; --text-muted: #6b6b76; --text-faint: #a2a2ac;
      --text-accent: #3d5bd9; --text-accent-hover: #2f49b8; --text-on-accent: #ffffff;
      --text-error: #d83a3a; --text-success: #2f9e62; --text-warning: #b7791f; --text-selection: rgba(61,91,217,0.2);
      --interactive-normal: #f0f0f3; --interactive-hover: #e6e6ea; --interactive-accent: #3d5bd9; --interactive-accent-hover: #2f49b8;
      --color-red: #d83a3a; --color-orange: #d9822b; --color-yellow: #b7791f; --color-green: #2f9e62;
      --color-cyan: #1b9aaa; --color-blue: #3d5bd9; --color-purple: #7c4dcc; --color-pink: #c2417a;
      --color-base-00: #ffffff; --color-base-10: #f7f7f9; --color-base-20: #f0f0f3; --color-base-30: #e3e3e8;
      --color-base-50: #a2a2ac; --color-base-70: #6b6b76; --color-base-100: #16161a;
      --font-text: -apple-system, "PingFang TC", "Helvetica Neue", sans-serif;
      --font-interface: var(--font-text); --font-monospace: ui-monospace, "SF Mono", Menlo, monospace;
      --font-text-size: 16px; --font-ui-small: 13px; --font-ui-smaller: 12px; --font-ui-medium: 15px;
      --radius-s: 4px; --radius-m: 8px; --radius-l: 12px;
      --size-4-1: 4px; --size-4-2: 8px; --size-4-3: 12px; --size-4-4: 16px; --size-4-6: 24px;
      --line-height-normal: 1.55; --h1-size: 1.6em; --h2-size: 1.35em; --h3-size: 1.18em; --h4-size: 1.05em;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background-primary: #1c1c1e; --background-primary-alt: #202023;
        --background-secondary: #242427; --background-secondary-alt: #2c2c30;
        --background-modifier-border: #333338; --background-modifier-border-hover: #44444a;
        --background-modifier-hover: rgba(255,255,255,0.06); --background-modifier-active-hover: rgba(157,174,255,0.16);
        --background-modifier-form-field: #2c2c30;
        --text-normal: #f2f2f4; --text-muted: #a1a1aa; --text-faint: #6e6e78;
        --text-accent: #9daeff; --text-accent-hover: #b8c4ff; --text-on-accent: #111113;
        --text-error: #f87171; --text-success: #4ade80; --text-warning: #fbbf24; --text-selection: rgba(157,174,255,0.25);
        --interactive-normal: #2c2c30; --interactive-hover: #36363b; --interactive-accent: #9daeff; --interactive-accent-hover: #b8c4ff;
        --color-red: #f87171; --color-orange: #fb923c; --color-yellow: #fbbf24; --color-green: #4ade80;
        --color-cyan: #22d3ee; --color-blue: #9daeff; --color-purple: #c4a7ff; --color-pink: #f472b6;
        --color-base-00: #1c1c1e; --color-base-10: #202023; --color-base-20: #242427; --color-base-30: #333338;
        --color-base-50: #6e6e78; --color-base-70: #a1a1aa; --color-base-100: #f2f2f4;
      }
    }
    html, body { margin: 0; padding: 0; background: transparent; }
    body { font: var(--font-text-size)/var(--line-height-normal) var(--font-text); color: var(--text-normal);
           -webkit-text-size-adjust: 100%; -webkit-tap-highlight-color: transparent; overflow-wrap: anywhere; }
    #dv-root { display: flow-root; }
    a, .internal-link { color: var(--text-accent); text-decoration: none; cursor: pointer; }
    .tag { color: var(--text-accent); background: var(--background-modifier-active-hover); border-radius: 999px; padding: 0 7px; font-size: .88em; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1em 0 .45em; }
    h1 { font-size: var(--h1-size); } h2 { font-size: var(--h2-size); } h3 { font-size: var(--h3-size); } h4 { font-size: var(--h4-size); }
    p { margin: .5em 0; }
    ul, ol { padding-left: 1.35em; margin: .4em 0; }
    li { margin: .15em 0; }
    code { font-family: var(--font-monospace); font-size: .86em; background: var(--background-secondary); padding: 1px 5px; border-radius: var(--radius-s); }
    pre { font-family: var(--font-monospace); font-size: 12.5px; background: var(--background-secondary); padding: 10px 12px; border-radius: var(--radius-m); overflow-x: auto; white-space: pre-wrap; }
    mark { background: rgba(250, 204, 21, .35); color: inherit; border-radius: 3px; }
    hr { border: none; border-top: 1px solid var(--background-modifier-border); margin: 1em 0; }
    img { max-width: 100%; border-radius: var(--radius-m); }
    .dv-table-wrap { overflow-x: auto; margin: .5em 0; border: 1px solid var(--background-modifier-border); border-radius: var(--radius-m); }
    table { border-collapse: collapse; width: 100%; font-size: 14px; }
    th, td { padding: 7px 10px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--background-modifier-border); }
    th { color: var(--text-muted); font-weight: 600; background: var(--background-secondary); white-space: nowrap; }
    tr:last-child td { border-bottom: none; }
    .dataview-result-list-li .dataview.small-text, .dataview.small-text { color: var(--text-muted); font-size: .85em; }
    .task-list-item { list-style: none; margin-left: -1.2em; }
    .task-list-item input { margin-right: 6px; transform: translateY(1px); }
    .task-list-item.is-checked { color: var(--text-muted); text-decoration: line-through; }
    button, .mod-cta { font: inherit; font-size: 14px; color: var(--text-normal); background: var(--interactive-normal);
             border: 1px solid var(--background-modifier-border); border-radius: var(--radius-m); padding: 6px 12px; }
    button.mod-cta, .mod-cta { background: var(--interactive-accent); color: var(--text-on-accent); border-color: transparent; }
    input, select, textarea { font: inherit; font-size: 15px; color: var(--text-normal); background: var(--background-modifier-form-field);
             border: 1px solid var(--background-modifier-border); border-radius: var(--radius-m); padding: 6px 9px; max-width: 100%; box-sizing: border-box; }
    .dv-error { color: var(--text-error); background: rgba(216, 58, 58, .08); border: 1px solid rgba(216, 58, 58, .25);
                border-radius: var(--radius-m); padding: 10px 12px; margin: 4px 0; font-size: 14px; }
    .dv-error pre { background: transparent; padding: 6px 0 0; margin: 0; color: inherit; }
    .dv-toast { position: fixed; left: 50%; bottom: 16px; transform: translateX(-50%); background: rgba(20,20,22,.9); color: #fff;
                padding: 8px 14px; border-radius: 999px; font-size: 14px; z-index: 9999; max-width: 86%; text-align: center; }
    .dv-empty { color: var(--text-muted); font-size: 14px; }
    """##

    static let script = ##"""
    (() => {
      "use strict";
      const CONFIG = window.__dv || {};
      const SOURCE = CONFIG.source || "";
      const BASE = "localocr-vault://app/";
      const bridge = (op, args) => window.webkit.messageHandlers.vault.postMessage(Object.assign({ op }, args || {}));
      const root = document.getElementById("dv-root");

      // ---------- 路徑 ----------
      const norm = (p) => String(p == null ? "" : (p.path || p)).replace(/\\/g, "/").replace(/^\/+|\/+$/g, "").replace(/\/{2,}/g, "/");
      const basename = (p) => { const s = norm(p); return s.slice(s.lastIndexOf("/") + 1); };
      const dirname = (p) => { const s = norm(p); const i = s.lastIndexOf("/"); return i < 0 ? "" : s.slice(0, i); };
      const extname = (p) => { const b = basename(p); const i = b.lastIndexOf("."); return i <= 0 ? "" : b.slice(i + 1).toLowerCase(); };
      const stem = (p) => basename(p).replace(/\.[^.]+$/, "");
      const resource = (p) => BASE + "file?path=" + encodeURIComponent(norm(p));
      const readText = (p) => bridge("read", { path: norm(p) });

      // ---------- Obsidian 的 HTMLElement 擴充 ----------
      function applyOptions(el, o) {
        if (o == null) return el;
        if (typeof o === "string") { el.textContent = o; return el; }
        if (o.cls) (Array.isArray(o.cls) ? o.cls : String(o.cls).split(/\s+/)).filter(Boolean).forEach((c) => el.classList.add(c));
        if (o.text != null) { if (o.text instanceof Node) el.appendChild(o.text); else el.textContent = String(o.text); }
        if (o.attr) for (const k of Object.keys(o.attr)) { const v = o.attr[k]; if (v === false || v == null) continue; el.setAttribute(k, v === true ? "" : String(v)); }
        for (const k of ["title", "href", "type", "placeholder"]) if (o[k] != null) el.setAttribute(k, String(o[k]));
        if (o.value != null) el.value = o.value;
        if (o.parent) o.parent.appendChild(el);
        return el;
      }
      function createEl(tag, o, cb) { const el = applyOptions(document.createElement(tag), o); if (cb) cb(el); return el; }
      const helpers = {
        createEl(tag, o, cb) { const el = applyOptions(document.createElement(tag), o); if (o && o.prepend) this.prepend(el); else this.appendChild(el); if (cb) cb(el); return el; },
        createDiv(o, cb) { return this.createEl("div", o, cb); },
        createSpan(o, cb) { return this.createEl("span", o, cb); },
        empty() { while (this.firstChild) this.removeChild(this.firstChild); },
      };
      for (const proto of [HTMLElement.prototype, DocumentFragment.prototype]) Object.assign(proto, helpers);
      Object.assign(HTMLElement.prototype, {
        addClass(...c) { this.classList.add(...c.flatMap((x) => String(x).split(/\s+/)).filter(Boolean)); },
        addClasses(c) { this.addClass(...c); },
        removeClass(...c) { this.classList.remove(...c); },
        removeClasses(c) { this.removeClass(...c); },
        toggleClass(c, v) { this.classList.toggle(c, v); },
        hasClass(c) { return this.classList.contains(c); },
        setText(t) { this.textContent = t == null ? "" : String(t); },
        getText() { return this.textContent; },
        setAttr(k, v) { if (v == null || v === false) this.removeAttribute(k); else this.setAttribute(k, v === true ? "" : String(v)); },
        setAttrs(o) { for (const k in o) this.setAttr(k, o[k]); },
        getAttr(k) { return this.getAttribute(k); },
        show() { this.style.display = ""; },
        hide() { this.style.display = "none"; },
        toggle(v) { this.style.display = v ? "" : "none"; },
        isShown() { return this.style.display !== "none"; },
        setCssStyles(s) { Object.assign(this.style, s); },
        setCssProps(p) { for (const k in p) this.style.setProperty(k, p[k]); },
        find(s) { return this.querySelector(s); },
        findAll(s) { return Array.from(this.querySelectorAll(s)); },
        onClickEvent(cb) { this.addEventListener("click", cb); },
      });
      window.createEl = createEl;
      window.createDiv = (o, cb) => createEl("div", o, cb);
      window.createSpan = (o, cb) => createEl("span", o, cb);
      window.createFragment = (cb) => { const f = document.createDocumentFragment(); if (cb) cb(f); return f; };

      // ---------- 日期（luxon 與 moment 的常用部分） ----------
      const pad = (n, w = 2) => String(n).padStart(w, "0");
      const WEEK = ["日", "一", "二", "三", "四", "五", "六"];
      class DvDate {
        constructor(d) { this._d = d instanceof Date ? new Date(d.getTime()) : new Date(d); this.ts = this._d.getTime(); }
        get year() { return this._d.getFullYear(); }
        get month() { return this._d.getMonth() + 1; }
        get day() { return this._d.getDate(); }
        get hour() { return this._d.getHours(); }
        get minute() { return this._d.getMinutes(); }
        get second() { return this._d.getSeconds(); }
        get weekday() { return this._d.getDay() || 7; }
        get isValid() { return !isNaN(this.ts); }
        toJSDate() { return new Date(this.ts); }
        toMillis() { return this.ts; }
        valueOf() { return this.ts; }
        toISODate() { return this.toFormat("yyyy-MM-dd"); }
        toISO() { return this._d.toISOString(); }
        toFormat(f) {
          const map = { yyyy: this.year, yy: pad(this.year % 100), MM: pad(this.month), M: this.month, dd: pad(this.day), d: this.day,
            HH: pad(this.hour), H: this.hour, mm: pad(this.minute), m: this.minute, ss: pad(this.second), s: this.second, EEE: WEEK[this._d.getDay()] };
          return String(f).replace(/yyyy|yy|MM|M|dd|d|HH|H|mm|m|ss|s|EEE/g, (t) => map[t]);
        }
        plus(o) {
          const d = new Date(this.ts); o = o || {};
          if (o.years) d.setFullYear(d.getFullYear() + o.years);
          if (o.months) d.setMonth(d.getMonth() + o.months);
          if (o.weeks) d.setDate(d.getDate() + 7 * o.weeks);
          if (o.days) d.setDate(d.getDate() + o.days);
          if (o.hours) d.setHours(d.getHours() + o.hours);
          if (o.minutes) d.setMinutes(d.getMinutes() + o.minutes);
          return new DvDate(d);
        }
        minus(o) { const n = {}; for (const k in o) n[k] = -o[k]; return this.plus(n); }
        startOf(unit) {
          const d = new Date(this.ts);
          if (unit === "year") d.setMonth(0, 1);
          else if (unit === "month") d.setDate(1);
          else if (unit === "week") d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
          d.setHours(0, 0, 0, 0);
          return new DvDate(d);
        }
        endOf(unit) { const next = this.startOf(unit).plus(unit === "year" ? { years: 1 } : unit === "month" ? { months: 1 } : unit === "week" ? { weeks: 1 } : { days: 1 }); return new DvDate(next.ts - 1); }
        diff(other, unit = "days") { const ms = this.ts - Number(other); const div = { days: 864e5, hours: 36e5, minutes: 6e4, seconds: 1e3 }[unit] || 1; const v = ms / div; return { [unit]: v, as: () => v, toMillis: () => ms }; }
        hasSame(other, unit) { return this.startOf(unit).ts === new DvDate(Number(other)).startOf(unit).ts; }
        toRelative() { const days = Math.round((Date.now() - this.ts) / 864e5); return days === 0 ? "今天" : days > 0 ? `${days} 天前` : `${-days} 天後`; }
        toLocaleString() { return this._d.toLocaleString("zh-TW"); }
        toString() { return this.hour || this.minute ? this.toFormat("yyyy-MM-dd HH:mm") : this.toFormat("yyyy-MM-dd"); }
      }
      const toDate = (v) => (v instanceof DvDate ? v._d : v instanceof Date ? v : v && v._d instanceof Date ? v._d : v == null ? new Date() : new Date(v));
      function moment(input) { const d = toDate(input); return makeMoment(isNaN(d) ? new Date(NaN) : new Date(d.getTime())); }
      function makeMoment(d) {
        const unitMs = { millisecond: 1, second: 1e3, minute: 6e4, hour: 36e5, day: 864e5, week: 6048e5 };
        const unitOf = (u) => String(u || "millisecond").replace(/s$/, "").replace(/^d$/, "day").replace(/^M$/, "month").replace(/^y$/, "year").replace(/^w$/, "week").replace(/^h$/, "hour");
        const m = {
          _d: d, _isAMomentObject: true,
          format(f = "YYYY-MM-DDTHH:mm:ss") {
            const map = { YYYY: d.getFullYear(), YY: pad(d.getFullYear() % 100), MM: pad(d.getMonth() + 1), M: d.getMonth() + 1, DD: pad(d.getDate()), D: d.getDate(),
              HH: pad(d.getHours()), H: d.getHours(), mm: pad(d.getMinutes()), ss: pad(d.getSeconds()), dddd: "星期" + WEEK[d.getDay()], ddd: WEEK[d.getDay()] };
            return String(f).replace(/\[([^\]]*)\]|YYYY|YY|MM|M|DD|D|HH|H|mm|ss|dddd|ddd/g, (t, lit) => (lit !== undefined ? lit : map[t]));
          },
          toDate: () => new Date(d.getTime()), toISOString: () => d.toISOString(), valueOf: () => d.getTime(), unix: () => Math.floor(d.getTime() / 1000),
          isValid: () => !isNaN(d), clone: () => makeMoment(new Date(d.getTime())),
          add(n, u) { const x = new Date(d.getTime()); const unit = unitOf(u); if (unit === "month") x.setMonth(x.getMonth() + n); else if (unit === "year") x.setFullYear(x.getFullYear() + n); else x.setTime(x.getTime() + n * (unitMs[unit] || 1)); return makeMoment(x); },
          subtract(n, u) { return m.add(-n, u); },
          startOf(u) { const x = new Date(d.getTime()); const unit = unitOf(u); if (unit === "year") x.setMonth(0, 1); if (unit === "month") x.setDate(1); if (unit === "week") x.setDate(x.getDate() - x.getDay()); x.setHours(0, 0, 0, 0); return makeMoment(x); },
          endOf(u) { return m.startOf(u).add(1, unitOf(u)).subtract(1, "millisecond"); },
          diff(o, u, float) { const ms = d.getTime() - toDate(o).getTime(); const unit = unitOf(u); const v = unit === "month" ? ms / (30.44 * 864e5) : unit === "year" ? ms / (365.25 * 864e5) : ms / (unitMs[unit] || 1); return float ? v : Math.trunc(v); },
          isBefore: (o) => d < toDate(o), isAfter: (o) => d > toDate(o), isSame: (o, u) => m.startOf(u || "day").valueOf() === moment(o).startOf(u || "day").valueOf(),
          year: () => d.getFullYear(), month: () => d.getMonth(), date: () => d.getDate(), day: () => d.getDay(), hour: () => d.getHours(), minute: () => d.getMinutes(),
          fromNow() { return new DvDate(d).toRelative(); }, toString: () => d.toString(),
        };
        return m;
      }
      moment.isMoment = (v) => !!(v && v._isAMomentObject);
      moment.now = () => Date.now();
      window.moment = moment;

      // ---------- 連結 ----------
      class Link {
        constructor(path, display, embed = false, subpath) { this.path = norm(path); this.display = display; this.embed = embed; this.subpath = subpath; this.type = "file"; }
        fileName() { return stem(this.path); }
        withDisplay(d) { return new Link(this.path, d, this.embed, this.subpath); }
        toEmbed() { return new Link(this.path, this.display, true, this.subpath); }
        obsidianLink() { return this.path; }
        markdown() { return this.toString(); }
        toString() { return `${this.embed ? "!" : ""}[[${this.path}${this.subpath || ""}${this.display ? "|" + this.display : ""}]]`; }
      }

      // ---------- 頁面索引 ----------
      let NOTES = [], FILES = [], PAGES = [], BYPATH = new Map(), BYNAME = new Map();
      function resolve(target) {
        if (target == null) return null;
        let t = norm(target instanceof Link ? target.path : target).split("|")[0].split("#")[0].trim();
        if (!t) return null;
        if (BYPATH.has(t)) return t;
        if (BYPATH.has(t + ".md")) return t + ".md";
        if (FILES.some((f) => f.path === t)) return t;
        const hit = BYNAME.get(stem(t).toLowerCase());
        return hit || null;
      }
      function coerce(v) {
        if (v == null) return null;
        if (Array.isArray(v)) return dvArray(v.map(coerce));
        const s = String(v).trim();
        if (s === "") return null;
        if (/^(true|false)$/i.test(s)) return s.toLowerCase() === "true";
        if (/^-?\d+(\.\d+)?$/.test(s) && !/^0\d/.test(s)) return Number(s);
        if (/^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$/.test(s)) { const d = new DvDate(s.replace(" ", "T")); if (d.isValid) return d; }
        const link = /^!?\[\[([^\]|#]+)(#[^\]|]*)?(?:\|([^\]]*))?\]\]$/.exec(s);
        if (link) return new Link(resolve(link[1]) || link[1], link[3], s.startsWith("!"), link[2]);
        return s;
      }
      function makePage(n) {
        const name = n.title || stem(n.path);
        const link = new Link(n.path, undefined);
        const tags = [];
        for (const raw of n.tags || []) {
          const parts = String(raw).replace(/^#/, "").split("/");
          for (let i = 1; i <= parts.length; i++) { const t = "#" + parts.slice(0, i).join("/"); if (!tags.includes(t)) tags.push(t); }
        }
        const file = {
          name, path: n.path, folder: dirname(n.path), ext: extname(n.path) || "md", link, size: n.size || 0,
          mtime: new DvDate(n.mtime || Date.now()), ctime: new DvDate(n.ctime || n.mtime || Date.now()),
          tags: dvArray(tags), etags: dvArray((n.tags || []).map((t) => "#" + String(t).replace(/^#/, ""))),
          aliases: dvArray(n.aliases || []), outlinks: dvArray([]), inlinks: dvArray([]), frontmatter: n.properties || {},
          tasks: dvArray((n.tasks || []).map((t, i) => ({ text: t.text, completed: !!t.done, checked: !!t.done, fullyCompleted: !!t.done,
            status: t.done ? "x" : " ", task: true, path: n.path, line: i, link, children: [], subtasks: [] }))),
        };
        file.mday = file.mtime.startOf("day"); file.cday = file.ctime.startOf("day"); file.lists = file.tasks;
        file.day = (() => { const m = /(\d{4}-\d{2}-\d{2})/.exec(name); return m ? new DvDate(m[1]) : null; })();
        const page = { file };
        for (const [key, value] of Object.entries(n.properties || {})) {
          const v = coerce(value);
          if (!(key in page)) page[key] = v;
          const safe = key.toLowerCase().replace(/\s+/g, "-");
          if (!(safe in page)) page[safe] = v;
        }
        return page;
      }
      function buildIndex(data) {
        NOTES = data.notes || []; FILES = data.files || [];
        BYPATH = new Map(); BYNAME = new Map();
        for (const n of NOTES) {
          BYPATH.set(n.path, n);
          const key = stem(n.path).toLowerCase();
          if (!BYNAME.has(key) || n.path.length < BYNAME.get(key).length) BYNAME.set(key, n.path);
          for (const a of n.aliases || []) if (!BYNAME.has(String(a).toLowerCase())) BYNAME.set(String(a).toLowerCase(), n.path);
        }
        PAGES = NOTES.map(makePage);
        const pageOf = new Map(PAGES.map((p) => [p.file.path, p]));
        for (let i = 0; i < NOTES.length; i++) {
          const out = [];
          for (const l of NOTES[i].links || []) { const r = resolve(l); const link = new Link(r || l); out.push(link); if (r && pageOf.has(r)) pageOf.get(r).file.inlinks.values.push(PAGES[i].file.link); }
          PAGES[i].file.outlinks = dvArray(out);
        }
        for (const p of PAGES) p.file.inlinks = dvArray(p.file.inlinks.values);
      }
      const pageFor = (path) => { const r = resolve(path); return r ? PAGES.find((p) => p.file.path === r) || null : null; };

      // ---------- DataArray ----------
      const groupKey = (v) => (v instanceof Link ? "L:" + v.path : v instanceof DvDate ? "D:" + v.ts : v && v.__dv ? "A:" + v.values.map(groupKey).join("|") : typeof v === "object" && v !== null ? "O:" + JSON.stringify(v) : typeof v + ":" + String(v));
      function compare(a, b) {
        if (a === b) return 0;
        if (a == null) return 1;
        if (b == null) return -1;
        if (a instanceof DvDate || b instanceof DvDate || a instanceof Date || b instanceof Date) return Number(a) - Number(b);
        if (a instanceof Link && b instanceof Link) return compare(a.fileName(), b.fileName());
        if (typeof a === "number" && typeof b === "number") return a - b;
        if (typeof a === "boolean" && typeof b === "boolean") return (a ? 1 : 0) - (b ? 1 : 0);
        if (a && a.__dv && b && b.__dv) { for (let i = 0; i < Math.min(a.length, b.length); i++) { const c = compare(a.values[i], b.values[i]); if (c) return c; } return a.length - b.length; }
        return String(a).localeCompare(String(b), "zh-Hant", { numeric: true });
      }
      const unwrap = (v) => (v && v.__dv ? v.values : Array.isArray(v) ? v : v === undefined ? [] : [v]);
      function dvArray(values) {
        const arr = values && values.__dv ? [...values.values] : Array.from(values == null ? [] : values);
        const api = { __dv: true, values: arr, length: arr.length };
        let proxy;
        Object.assign(api, {
          where: (f) => dvArray(arr.filter(f)), filter: (f) => dvArray(arr.filter(f)),
          map: (f) => dvArray(arr.map(f)), flatMap: (f) => dvArray(arr.flatMap((x, i) => unwrap(f(x, i)))),
          mutate: (f) => { arr.forEach(f); return proxy; },
          limit: (n) => dvArray(arr.slice(0, n)), slice: (a, b) => dvArray(arr.slice(a, b)),
          concat: (o) => dvArray(arr.concat(unwrap(o))),
          indexOf: (x, from) => arr.indexOf(x, from), find: (f) => arr.find(f), findIndex: (f) => arr.findIndex(f), includes: (x) => arr.includes(x),
          join: (s) => arr.map(toText).join(s == null ? ", " : s),
          sort: (key, dir = "asc", cmp) => { const k = typeof key === "function" ? key : (x) => x; const out = [...arr].sort((a, b) => { const r = (cmp || compare)(k(a), k(b)); return dir === "desc" ? -r : r; }); return dvArray(out); },
          sortInPlace: (key, dir, cmp) => proxy.sort(key, dir, cmp),
          groupBy: (key, cmp) => { const groups = new Map(); for (const x of arr) { const g = key(x); const id = groupKey(g); if (!groups.has(id)) groups.set(id, { key: g, rows: [] }); groups.get(id).rows.push(x); } return dvArray([...groups.values()].map((g) => ({ key: g.key, rows: dvArray(g.rows) }))).sort((g) => g.key, "asc", cmp); },
          groupIn: (key) => proxy.groupBy(key),
          distinct: (key, cmp) => { const k = key || ((x) => x); const seen = new Set(); return dvArray(arr.filter((x) => { const id = groupKey(k(x)); if (seen.has(id)) return false; seen.add(id); return true; })); },
          every: (f) => arr.every(f), some: (f) => arr.some(f), none: (f) => !arr.some(f),
          first: () => arr[0], last: () => arr[arr.length - 1],
          to: (k) => dvArray(arr.flatMap((x) => unwrap(x == null ? undefined : x[k]))),
          into: (k) => dvArray(arr.flatMap((x) => unwrap(x == null ? undefined : x[k]))),
          expand: (k) => { const out = []; const walk = (x) => { out.push(x); for (const c of unwrap(x && x[k])) walk(c); }; arr.forEach(walk); return dvArray(out); },
          forEach: (f) => arr.forEach(f), array: () => [...arr], toString: () => arr.map(toText).join(", "),
          sum: () => arr.reduce((a, b) => a + (Number(b) || 0), 0),
          avg: () => (arr.length ? proxy.sum() / arr.length : 0),
          min: () => [...arr].sort(compare)[0], max: () => [...arr].sort(compare).pop(),
          reduce: (f, init) => arr.reduce(f, init),
          [Symbol.iterator]: () => arr[Symbol.iterator](),
        });
        proxy = new Proxy(api, {
          get(target, prop) {
            if (typeof prop === "symbol" || prop in target) return target[prop];
            if (/^\d+$/.test(prop)) return arr[Number(prop)];
            return dvArray(arr.flatMap((x) => unwrap(x == null ? undefined : x[prop])));
          },
          has(target, prop) { return prop in target || (typeof prop === "string" && /^\d+$/.test(prop) && Number(prop) < arr.length); },
        });
        return proxy;
      }

      // ---------- 顯示 ----------
      const escapeHTML = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
      function inlineMarkdown(text) {
        const codes = [];
        let s = escapeHTML(text).replace(/`([^`]+)`/g, (_, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
        s = s.replace(/!?\[\[([^\]|#]+)(#[^\]|]*)?(?:\|([^\]]*))?\]\]/g, (_, target, sub, alias) => `<a class="internal-link" data-href="${target.trim()}">${alias || stem(target) + (sub ? sub.replace("#", " › ") : "")}</a>`)
          .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a class="external-link" href="$2">$1</a>')
          .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/__([^_]+)__/g, "<strong>$1</strong>")
          .replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>").replace(/(^|[^_\w])_([^_\n]+)_/g, "$1<em>$2</em>")
          .replace(/~~([^~]+)~~/g, "<del>$1</del>").replace(/==([^=]+)==/g, "<mark>$1</mark>")
          .replace(/(^|\s)#([\p{L}\p{N}_/-]+)/gu, '$1<a class="tag" data-tag="$2">#$2</a>')
          .replace(/\n/g, "<br>");
        return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[Number(i)]}</code>`);
      }
      function toText(v) {
        if (v == null) return "";
        if (v instanceof Link) return v.display || v.fileName();
        if (v instanceof DvDate) return v.toString();
        if (v && v.__dv) return v.values.map(toText).join(", ");
        if (Array.isArray(v)) return v.map(toText).join(", ");
        if (typeof v === "object") return v.toString !== Object.prototype.toString ? v.toString() : JSON.stringify(v);
        return String(v);
      }
      function renderValue(v, el, inline = false) {
        if (v == null || v === "") return el;
        if (v instanceof Node) { el.appendChild(v); return el; }
        if (v instanceof Link) {
          if (v.embed && /^(png|jpe?g|gif|webp|svg|heic|bmp)$/.test(extname(v.path))) { const img = el.createEl("img"); img.src = resource(resolve(v.path) || v.path); return el; }
          const a = el.createEl("a", { cls: "internal-link", text: v.display || v.fileName() + (v.subpath ? v.subpath.replace("#", " › ") : "") });
          a.dataset.href = v.path + (v.subpath || "");
          return el;
        }
        if (v instanceof DvDate) { el.appendChild(document.createTextNode(v.toString())); return el; }
        const items = v && v.__dv ? v.values : Array.isArray(v) ? v : null;
        if (items) {
          if (items.length <= 1 || inline) { items.forEach((x, i) => { if (i) el.appendChild(document.createTextNode(", ")); renderValue(x, el, true); }); return el; }
          const ul = el.createEl("ul"); for (const x of items) renderValue(x, ul.createEl("li"), true); return el;
        }
        if (typeof v === "object") {
          if (typeof v.then === "function") { v.then((r) => { renderValue(r, el, inline); scheduleHeight(); }); return el; }
          if (v.toString !== Object.prototype.toString) { el.appendChild(document.createTextNode(v.toString())); return el; }
          const ul = el.createEl("ul"); for (const k of Object.keys(v)) { const li = ul.createEl("li"); li.createEl("strong", { text: k + "：" }); renderValue(v[k], li, true); } return el;
        }
        if (typeof v === "boolean") { el.appendChild(document.createTextNode(v ? "✓" : "✗")); return el; }
        const span = document.createElement("span"); span.innerHTML = inlineMarkdown(String(v));
        while (span.firstChild) el.appendChild(span.firstChild);
        return el;
      }

      // ---------- dv ----------
      const parseCSV = (text) => {
        const rows = []; let row = [], field = "", quoted = false;
        for (let i = 0; i < text.length; i++) {
          const c = text[i];
          if (quoted) { if (c === '"' && text[i + 1] === '"') { field += '"'; i++; } else if (c === '"') quoted = false; else field += c; continue; }
          if (c === '"') quoted = true; else if (c === ",") { row.push(field); field = ""; } else if (c === "\n" || c === "\r") { if (c === "\r" && text[i + 1] === "\n") i++; row.push(field); rows.push(row); row = []; field = ""; } else field += c;
        }
        if (field !== "" || row.length) { row.push(field); rows.push(row); }
        const [head, ...body] = rows.filter((r) => r.some((x) => x !== ""));
        return (body || []).map((r) => Object.fromEntries((head || []).map((h, i) => [h, coerce(r[i])])));
      };
      function sourceMatcher(source) {
        const term = (raw) => {
          let t = raw.trim().replace(/^\(+|\)+$/g, ""); let negate = false;
          if (/^[-!]/.test(t)) { negate = true; t = t.slice(1).trim(); }
          let test = () => true;
          if (t.startsWith("#")) { const tag = t.slice(1).toLowerCase(); test = (p) => p.file.tags.values.some((x) => x.slice(1).toLowerCase() === tag); }
          else if (/^(".*"|'.*')$/.test(t)) { const path = norm(t.slice(1, -1)); test = (p) => path === "" || p.file.path === path || p.file.path === path + ".md" || p.file.path.startsWith(path + "/"); }
          else if (/^\[\[.*\]\]$/.test(t)) { const target = resolve(t.slice(2, -2)); test = (p) => p.file.outlinks.values.some((l) => l.path === target) || p.file.path === target; }
          else if (/^outgoing\(\[\[(.*)\]\]\)$/.test(t)) { const target = resolve(/^outgoing\(\[\[(.*)\]\]\)$/.exec(t)[1]); const page = pageFor(target); const outs = new Set(page ? page.file.outlinks.values.map((l) => l.path) : []); test = (p) => outs.has(p.file.path); }
          return negate ? (p) => !test(p) : test;
        };
        const ors = String(source).split(/\s+or\s+|\s*\|\|\s*/i).map((part) => part.split(/\s+and\s+|\s*&&\s*/i).map(term));
        return (p) => ors.some((ands) => ands.every((t) => t(p)));
      }
      const dv = {
        container: root,
        el(tag, text, o) { const e = document.createElement(tag); if (text instanceof Node) e.appendChild(text); else if (text != null && text !== "") renderValue(text, e, true); applyOptions(e, o ? { cls: o.cls, attr: o.attr } : null); (o && o.container || root).appendChild(e); return e; },
        header(level, text, o) { return dv.el("h" + Math.min(Math.max(Number(level) || 1, 1), 6), text, o); },
        paragraph(text, o) { return dv.el("p", text, o); },
        span(text, o) { return dv.el("span", text, o); },
        list(items) { const ul = root.createEl("ul", { cls: ["dataview", "list-view-ul"] }); for (const it of unwrap(items)) renderValue(it, ul.createEl("li", { cls: "dataview-result-list-li" })); if (!unwrap(items).length) root.createDiv({ cls: "dv-empty", text: "沒有結果" }); return ul; },
        taskList(tasks, group = true) {
          const list = unwrap(tasks);
          const draw = (parent, items) => { const ul = parent.createEl("ul", { cls: "contains-task-list" }); for (const t of items) { const li = ul.createEl("li", { cls: ["task-list-item", t.completed ? "is-checked" : ""].filter(Boolean) }); const box = li.createEl("input", { type: "checkbox" }); box.checked = !!t.completed; box.disabled = true; renderValue(t.text, li, true); } };
          if (!list.length) { root.createDiv({ cls: "dv-empty", text: "沒有待辦" }); return; }
          if (!group) return draw(root, list);
          const groups = new Map(); for (const t of list) { const p = t.path || ""; if (!groups.has(p)) groups.set(p, []); groups.get(p).push(t); }
          for (const [path, items] of groups) { const h = root.createEl("h4"); renderValue(new Link(path), h); draw(root, items); }
        },
        table(headers, rows) {
          const wrap = root.createDiv({ cls: "dv-table-wrap" });
          const table = wrap.createEl("table", { cls: ["dataview", "table-view-table"] });
          const head = table.createEl("thead").createEl("tr");
          for (const h of unwrap(headers)) renderValue(h, head.createEl("th"), true);
          const body = table.createEl("tbody");
          for (const r of unwrap(rows)) { const tr = body.createEl("tr"); for (const c of unwrap(r)) renderValue(c, tr.createEl("td")); }
          if (!unwrap(rows).length) wrap.createDiv({ cls: "dv-empty", text: "沒有結果" }).style.padding = "8px 10px";
          return table;
        },
        markdownTable(headers, rows) { const h = unwrap(headers).map(toText); return ["| " + h.join(" | ") + " |", "|" + h.map(() => " --- |").join(""), ...unwrap(rows).map((r) => "| " + unwrap(r).map((c) => (c instanceof Link ? c.toString() : toText(c))).join(" | ") + " |")].join("\n"); },
        markdownList(items) { return unwrap(items).map((x) => "- " + (x instanceof Link ? x.toString() : toText(x))).join("\n"); },
        markdownTaskList(tasks) { return unwrap(tasks).map((t) => `- [${t.completed ? "x" : " "}] ${t.text}`).join("\n"); },
        pages(source) { const list = source && String(source).trim() ? PAGES.filter(sourceMatcher(source)) : PAGES; return dvArray(list); },
        pagePaths(source) { return dv.pages(source).file.path; },
        page(path) { return pageFor(path); },
        current() { return pageFor(SOURCE) || makePage({ path: SOURCE, tags: [], properties: {} }); },
        array: (v) => dvArray(v), isArray: (v) => Array.isArray(v) || !!(v && v.__dv),
        fileLink: (path, embed = false, display) => new Link(path, display, embed),
        sectionLink: (path, section, embed = false, display) => new Link(path, display || section, embed, "#" + section),
        blockLink: (path, block, embed = false, display) => new Link(path, display, embed, "#^" + block),
        date(v) { if (v == null) return null; if (v instanceof DvDate) return v; if (v === "today") return new DvDate(new Date()).startOf("day"); if (v === "now") return new DvDate(new Date()); if (v === "tomorrow") return new DvDate(new Date()).startOf("day").plus({ days: 1 }); if (v === "yesterday") return new DvDate(new Date()).startOf("day").minus({ days: 1 }); const d = new DvDate(v instanceof Link ? stem(v.path) : v); return d.isValid ? d : null; },
        duration: (s) => { const m = /(\d+)\s*(d|day|h|hour|m|min|w|week)/i.exec(String(s)); return m ? { days: /^d/i.test(m[2]) ? Number(m[1]) : 0, hours: /^h/i.test(m[2]) ? Number(m[1]) : 0, weeks: /^w/i.test(m[2]) ? Number(m[1]) : 0 } : null; },
        compare, equal: (a, b) => compare(a, b) === 0, parse: (v) => coerce(v), clone: (v) => (v && v.__dv ? dvArray(v.values) : JSON.parse(JSON.stringify(v))),
        luxon: { DateTime: { now: () => new DvDate(new Date()), local: () => new DvDate(new Date()), fromISO: (s) => new DvDate(s), fromJSDate: (d) => new DvDate(d), fromMillis: (ms) => new DvDate(ms), fromFormat: (s) => new DvDate(s) }, Duration: { fromObject: (o) => o } },
        io: {
          load: (path) => readText(resolve(path) || path),
          csv: async (path) => dvArray(parseCSV(await readText(resolve(path) || path))),
          normalize: (path) => resolve(path) || norm(path),
        },
        async view(path, input) {
          const p = norm(path);
          const candidates = [p + ".js", p + "/view.js", p];
          let code = null, base = p;
          for (const c of candidates) { try { code = await readText(c); base = c.endsWith("/view.js") ? p + "/view" : p; break; } catch (e) {} }
          if (code == null) throw new Error("找不到 dv.view 的檔案：" + p);
          try { const css = await readText(base.replace(/\.js$/, "") + ".css"); document.head.appendChild(createEl("style", { text: css })); } catch (e) {}
          return run(code, input);
        },
        execute() { root.createDiv({ cls: "dv-empty", text: "dv.execute（DQL 查詢）目前還不支援" }); },
        executeJs(code) { return run(code); },
        api: null, settings: { tableIdColumnName: "File", defaultDateFormat: "yyyy-MM-dd" },
      };

      // ---------- app ----------
      const fileObject = (path) => {
        const p = norm(path);
        const note = BYPATH.get(p); const file = FILES.find((f) => f.path === p);
        if (!note && !file) return null;
        const item = note || file;
        return { path: p, name: basename(p), basename: stem(p), extension: extname(p), parent: { path: dirname(p), name: basename(dirname(p)) }, stat: { mtime: item.mtime || 0, ctime: item.ctime || item.mtime || 0, size: item.size || 0 }, vault: null };
      };
      const adapter = {
        read: (p) => readText(p),
        cachedRead: (p) => readText(p),
        write: (p, data) => bridge("write", { path: norm(p), text: String(data) }),
        append: async (p, data) => { let old = ""; try { old = await readText(p); } catch (e) {} return bridge("write", { path: norm(p), text: old + String(data) }); },
        exists: (p) => bridge("exists", { path: norm(p) }),
        list: (p) => bridge("list", { path: norm(p) }),
        readBinary: async (p) => { const r = await fetch(resource(p)); if (!r.ok) throw new Error("找不到檔案：" + norm(p)); return r.arrayBuffer(); },
        getResourcePath: (p) => resource(p),
        mkdir: async () => {},
        stat: async (p) => { const f = fileObject(p); return f ? { type: "file", ...f.stat } : null; },
        remove: async () => { throw new Error("DataviewJS 不能刪除檔案"); },
        rename: async () => { throw new Error("DataviewJS 不能搬移檔案"); },
      };
      const vault = {
        adapter, configDir: ".obsidian",
        getName: () => CONFIG.vault || "Vault",
        getAbstractFileByPath: (p) => fileObject(p),
        getFileByPath: (p) => fileObject(p),
        getFiles: () => [...NOTES, ...FILES].map((f) => fileObject(f.path)),
        getMarkdownFiles: () => NOTES.map((n) => fileObject(n.path)),
        getAllLoadedFiles: () => [...NOTES, ...FILES].map((f) => fileObject(f.path)),
        read: (f) => readText(f.path || f), cachedRead: (f) => readText(f.path || f),
        modify: (f, text) => adapter.write(f.path || f, text),
        create: async (p, text) => { await adapter.write(p, text); return { path: norm(p) }; },
        process: async (f, fn) => { const text = fn(await readText(f.path || f)); await adapter.write(f.path || f, text); return text; },
        getResourcePath: (f) => resource(f.path || f),
        on: () => ({}), off: () => {},
      };
      const workspace = {
        openLinkText: (link) => bridge("open", { link: String(link && link.path ? link.path : link) }),
        getLeaf: () => ({ openFile: (f) => bridge("open", { link: f.path || String(f) }), openLinkText: (l) => bridge("open", { link: String(l) }) }),
        getActiveFile: () => fileObject(SOURCE) || { path: SOURCE, basename: stem(SOURCE), name: basename(SOURCE), extension: "md" },
        on: () => ({}), off: () => {}, onLayoutReady: (cb) => cb(), trigger: () => {},
      };
      const metadataCache = {
        getFileCache(f) { const p = pageFor(f && f.path ? f.path : f); if (!p) return null; return { frontmatter: p.file.frontmatter, tags: p.file.etags.values.map((tag) => ({ tag })), links: p.file.outlinks.values.map((l) => ({ link: l.path })) }; },
        getCache(path) { return metadataCache.getFileCache(path); },
        getFirstLinkpathDest(link) { const r = resolve(link); return r ? fileObject(r) : null; },
        get resolvedLinks() { const out = {}; for (const p of PAGES) { out[p.file.path] = {}; for (const l of p.file.outlinks.values) out[p.file.path][l.path] = (out[p.file.path][l.path] || 0) + 1; } return out; },
        on: () => ({}), off: () => {},
      };
      const app = { vault, workspace, metadataCache, isMobile: true,
        plugins: { enabledPlugins: new Set(["dataview"]), plugins: { dataview: { api: dv } }, getPlugin: (n) => (n === "dataview" ? { api: dv } : null) } };
      dv.app = app; dv.api = dv;
      window.app = app; window.DataviewAPI = dv;

      class Notice {
        constructor(message, timeout = 3500) { this.el = document.body.createDiv({ cls: "dv-toast", text: String(message) }); this.timer = setTimeout(() => this.hide(), timeout); }
        setMessage(m) { this.el.textContent = String(m); return this; }
        hide() { clearTimeout(this.timer); this.el.remove(); }
      }
      window.Notice = Notice;

      // 剪貼簿：網頁的 navigator.clipboard 在 App 裡不能用，改由 App 複製與貼上
      try {
        Object.defineProperty(navigator, "clipboard", {
          configurable: true,
          value: { writeText: (text) => bridge("copy", { text: String(text) }), readText: () => bridge("paste") },
        });
      } catch (e) {}

      // ---------- 互動與高度 ----------
      document.addEventListener("click", (event) => {
        const a = event.target.closest && event.target.closest("a");
        if (!a) return;
        if (a.classList.contains("internal-link")) { event.preventDefault(); bridge("open", { link: a.dataset.href || a.getAttribute("href") || a.textContent }); }
        else if (/^https?:/i.test(a.getAttribute("href") || "")) { event.preventDefault(); bridge("openURL", { url: a.getAttribute("href") }); }
        else if (a.classList.contains("tag")) event.preventDefault();
      }, true);
      let heightTimer = null, lastHeight = 0;
      function scheduleHeight() {
        clearTimeout(heightTimer);
        heightTimer = setTimeout(() => { const h = Math.ceil(root.getBoundingClientRect().height); if (Math.abs(h - lastHeight) > 1) { lastHeight = h; bridge("height", { value: h }).catch(() => {}); } }, 60);
      }
      new ResizeObserver(scheduleHeight).observe(root);
      window.addEventListener("load", scheduleHeight);

      // ---------- 執行 ----------
      const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
      // 跟 Dataview 一樣只傳 dv 與 input；app、moment、Notice 是全域變數（程式碼可以自己宣告同名的變數）
      async function run(code, input) {
        const fn = new AsyncFunction("dv", "input", code);
        return fn.call(dv, dv, input);
      }
      (async () => {
        try {
          buildIndex(await bridge("index"));
          await run(CONFIG.code || "");
          if (!root.childNodes.length) root.createDiv({ cls: "dv-empty", text: "（這段 DataviewJS 沒有輸出）" });
        } catch (error) {
          const box = root.createDiv({ cls: "dv-error" });
          box.createEl("strong", { text: "DataviewJS 錯誤" });
          box.createEl("pre", { text: String(error && error.message ? error.message : error) });
        }
        scheduleHeight();
      })();
    })();
    """##
}
