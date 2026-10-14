import Foundation

// MARK: - Dataview 查詢語言（DQL）
//
// ```dataview 區塊與 dv.execute／dv.query 的查詢引擎，跟 DataviewShim 跑在同一個網頁裡（用 window.__dvi 的資料與顯示函式）：
// - 查詢：TABLE [WITHOUT ID] 欄位 AS "名稱"…、LIST [運算式]、TASK、CALENDAR 日期；FROM（資料夾、#標籤、[[連結]]、outgoing、and／or／否定、括號）、
//   WHERE、SORT（多個鍵、ASC／DESC）、GROUP BY … AS、FLATTEN … AS、LIMIT
// - 運算式：欄位（file.name、row["名稱"]、[[連結]].欄位、this）、算術與比較、and／or／!、清單、物件、lambda、日期與期間運算
// - 函式：date、dur、contains、length、map、filter、sort、join、regexreplace、dateformat、choice、default… 等 Dataview 的函式
// - 待辦：[due:: 日期] 與 📅⏳🛫✅ 的日期；TASK 結果可以打勾（改回原本的筆記）
// - 行內查詢：`= 運算式` 與 `$= JavaScript`（window.__dvEvaluate，由編輯器呼叫）

enum DataviewQuery {
    static let script = ##"""
    (() => {
      "use strict";
      const I = window.__dvi;
      if (!I) return;
      const { dv, root, bridge, dvArray, unwrap, Link, DvDate, compare, groupKey, renderValue, toText, pageFor, resolve, coerce, sourceMatcher, stem, norm } = I;

      // ================= 期間（duration） =================
      class DvDuration {
        constructor(ms = 0, months = 0) { this.ms = ms; this.monthsPart = months; this.__duration = true; }
        get years() { return (this.monthsPart / 12) + this.ms / (365.25 * 864e5); }
        get months() { return this.monthsPart + this.ms / (30.44 * 864e5); }
        get weeks() { return this.ms / 6048e5 + this.monthsPart * 4.348; }
        get days() { return this.ms / 864e5 + this.monthsPart * 30.44; }
        get hours() { return this.days * 24; }
        get minutes() { return this.hours * 60; }
        get seconds() { return this.minutes * 60; }
        valueOf() { return this.ms + this.monthsPart * 30.44 * 864e5; }
        toString() {
          const parts = []; let rest = this.ms;
          if (this.monthsPart) { const y = Math.trunc(this.monthsPart / 12), m = this.monthsPart % 12; if (y) parts.push(`${y} 年`); if (m) parts.push(`${m} 個月`); }
          const units = [[6048e5, "週"], [864e5, "天"], [36e5, "小時"], [6e4, "分鐘"], [1e3, "秒"]];
          for (const [size, name] of units) { const n = Math.trunc(Math.abs(rest) / size); if (n) { parts.push(`${rest < 0 ? "-" : ""}${n} ${name}`); rest -= Math.sign(rest) * n * size; } }
          return parts.length ? parts.join(" ") : "0 秒";
        }
      }
      const UNIT = [
        [/^(y|yr|yrs|year|years|年)$/i, 0, 12], [/^(mo|mos|month|months|個月|月)$/i, 0, 1], [/^(w|wk|wks|week|weeks|週|周)$/i, 6048e5, 0],
        [/^(d|day|days|天|日)$/i, 864e5, 0], [/^(h|hr|hrs|hour|hours|小時|時)$/i, 36e5, 0], [/^(m|min|mins|minute|minutes|分鐘|分)$/i, 6e4, 0], [/^(s|sec|secs|second|seconds|秒)$/i, 1e3, 0],
      ];
      function parseDuration(text) {
        if (text instanceof DvDuration) return text;
        if (typeof text === "number") return new DvDuration(text);
        let ms = 0, months = 0, found = false;
        for (const m of String(text).matchAll(/(-?\d+(?:\.\d+)?)\s*([a-zA-Z一-鿿]+)/g)) {
          const unit = UNIT.find(([re]) => re.test(m[2]));
          if (!unit) continue;
          found = true; const n = Number(m[1]);
          if (unit[2]) months += n * unit[2]; else ms += n * unit[1];
        }
        return found ? new DvDuration(ms, months) : null;
      }

      // ================= 日期 =================
      const DAY = 864e5;
      function parseDate(value, format) {
        if (value == null) return null;
        if (value instanceof DvDate) return value;
        if (value instanceof Date) return new DvDate(value);
        if (value instanceof Link) { const page = pageFor(value.path); if (page && page.file.day) return page.file.day; return parseDate(stem(value.path)); }
        if (typeof value === "number") return new DvDate(value);
        const s = String(value).trim();
        const now = new Date();
        const today = new DvDate(now).startOf("day");
        const keywords = {
          today, now: new DvDate(now), tomorrow: today.plus({ days: 1 }), yesterday: today.minus({ days: 1 }),
          sow: today.startOf("week"), eow: today.endOf("week"), som: today.startOf("month"), eom: today.endOf("month"), soy: today.startOf("year"), eoy: today.endOf("year"),
        };
        if (keywords[s.toLowerCase()]) return keywords[s.toLowerCase()];
        if (format) {
          const tokens = []; const re = String(format).replace(/yyyy|yy|MM|M|dd|d|HH|H|mm|ss|[.*+?^${}()|[\]\\]/g, (t) => {
            const map = { yyyy: "(\\d{4})", yy: "(\\d{2})", MM: "(\\d{2})", M: "(\\d{1,2})", dd: "(\\d{2})", d: "(\\d{1,2})", HH: "(\\d{2})", H: "(\\d{1,2})", mm: "(\\d{2})", ss: "(\\d{2})" };
            if (map[t]) { tokens.push(t); return map[t]; } return "\\" + t;
          });
          const m = new RegExp("^" + re + "$").exec(s);
          if (!m) return null;
          const parts = { y: now.getFullYear(), M: 1, d: 1, H: 0, m: 0, s: 0 };
          tokens.forEach((t, i) => { const n = Number(m[i + 1]); if (t.startsWith("y")) parts.y = t === "yy" ? 2000 + n : n; else if (t.startsWith("M")) parts.M = n; else if (t.startsWith("d")) parts.d = n; else if (t.startsWith("H")) parts.H = n; else if (t === "mm") parts.m = n; else if (t === "ss") parts.s = n; });
          return new DvDate(new Date(parts.y, parts.M - 1, parts.d, parts.H, parts.m, parts.s));
        }
        let m = /^(\d{4})-(\d{2})(?:-(\d{2}))?(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(s);
        if (m) return new DvDate(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3] || 1), Number(m[4] || 0), Number(m[5] || 0), Number(m[6] || 0)));
        m = /(\d{4})-(\d{2})-(\d{2})/.exec(s);
        if (m) return new DvDate(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
        return null;
      }
      // DvDate 加上 Dataview 用到的欄位
      for (const [name, get] of [["weekyear", (d) => d.year], ["quarter", (d) => Math.ceil(d.month / 3)], ["millisecond", (d) => d._d.getMilliseconds()], ["zone", () => "local"]]) {
        if (!(name in DvDate.prototype)) Object.defineProperty(DvDate.prototype, name, { get() { return get(this); } });
      }
      if (!("weekNumber" in DvDate.prototype)) Object.defineProperty(DvDate.prototype, "weekNumber", { get() { const d = new Date(Date.UTC(this.year, this.month - 1, this.day)); const dayNum = d.getUTCDay() || 7; d.setUTCDate(d.getUTCDate() + 4 - dayNum); const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1)); return Math.ceil(((d - yearStart) / DAY + 1) / 7); } });

      // ================= 值的工具 =================
      const isArr = (v) => Array.isArray(v) || !!(v && v.__dv);
      const arr = (v) => (v && v.__dv ? v.values : Array.isArray(v) ? v : v == null ? [] : [v]);
      const isDate = (v) => v instanceof DvDate;
      const isDur = (v) => v instanceof DvDuration;
      const isObj = (v) => v !== null && typeof v === "object" && !isArr(v) && !(v instanceof Link) && !isDate(v) && !isDur(v) && !(v instanceof Node) && !v.__lambda;
      function truthy(v) {
        if (v == null || v === false || v === 0 || v === "") return false;
        if (isArr(v)) return arr(v).length > 0;
        if (isDur(v)) return v.valueOf() !== 0;
        return true;
      }
      function equal(a, b) {
        if (a === b) return true;
        if (a == null || b == null) return a == null && b == null;
        if (a instanceof Link && b instanceof Link) return (resolve(a.path) || a.path) === (resolve(b.path) || b.path);
        if (a instanceof Link && typeof b === "string") return a.path === b || stem(a.path) === b;
        if (isDate(a) || isDate(b) || isDur(a) || isDur(b)) return Number(a) === Number(b);
        if (isArr(a) && isArr(b)) { const x = arr(a), y = arr(b); return x.length === y.length && x.every((v, i) => equal(v, y[i])); }
        if (isObj(a) && isObj(b)) { const ka = Object.keys(a), kb = Object.keys(b); return ka.length === kb.length && ka.every((k) => equal(a[k], b[k])); }
        if (typeof a === "number" && typeof b === "string") return String(a) === b;
        if (typeof b === "number" && typeof a === "string") return String(b) === a;
        return false;
      }
      const cmp = (a, b) => {
        if (a == null && b == null) return 0;
        if (a == null) return -1;
        if (b == null) return 1;
        if (isDur(a) || isDur(b)) return Number(a) - Number(b);
        return compare(a, b);
      };
      const typeOf = (v) => (v == null ? "null" : isArr(v) ? "array" : v instanceof Link ? "link" : isDate(v) ? "date" : isDur(v) ? "duration" : v.__lambda ? "function" : typeof v === "object" ? "object" : typeof v);
      const textOf = (v) => (isDur(v) ? v.toString() : toText(v));

      // 欄位：page.field、page["Field Name"]、[[連結]].欄位、日期的 year/month…、清單自動展開（rows.file.name）
      function field(obj, name) {
        if (obj == null) return null;
        if (obj && obj.__dv) return dvArray(obj.values.flatMap((x) => { const v = field(x, name); return v == null ? [] : arr(v); }));
        if (Array.isArray(obj)) return typeof name === "number" ? obj[name] : dvArray(obj.flatMap((x) => { const v = field(x, name); return v == null ? [] : arr(v); }));
        if (obj instanceof Link) { const page = pageFor(obj.path); return page ? field(page, name) : null; }
        if (typeof name === "number") return typeof obj === "string" ? obj[name] : null;
        if (isDate(obj) || isDur(obj)) { const v = obj[name]; return typeof v === "function" ? null : v === undefined ? null : v; }
        if (typeof obj === "string") return name === "length" ? obj.length : null;
        if (typeof obj !== "object") return null;
        if (Object.prototype.hasOwnProperty.call(obj, name) || name in obj) { const v = obj[name]; return v === undefined ? null : v; }
        const lower = String(name).toLowerCase();
        const safe = lower.replace(/\s+/g, "-");
        for (const key of Object.keys(obj)) { const k = key.toLowerCase(); if (k === lower || k.replace(/\s+/g, "-") === safe) return obj[key]; }
        return null;
      }

      // ================= 語法分析 =================
      class DqlError extends Error {}
      const KEYWORDS = new Set(["and", "or", "true", "false", "null", "this", "row"]);
      function tokenize(src) {
        const tokens = []; let i = 0;
        const push = (type, value, start) => tokens.push({ type, value, start, end: i });
        while (i < src.length) {
          const c = src[i];
          if (/\s/.test(c)) { i++; continue; }
          const start = i;
          if (c === '"' || c === "'") {
            let s = ""; i++;
            while (i < src.length && src[i] !== c) { if (src[i] === "\\" && i + 1 < src.length) { i++; s += ({ n: "\n", t: "\t" })[src[i]] || src[i]; } else s += src[i]; i++; }
            if (src[i] !== c) throw new DqlError("字串沒有結尾的引號");
            i++; push("str", s, start); continue;
          }
          if (src.startsWith("[[", i)) { const end = src.indexOf("]]", i); if (end < 0) throw new DqlError("連結沒有結尾的 ]]"); const inner = src.slice(i + 2, end); i = end + 2; push("link", inner, start); continue; }
          if (/\d/.test(c)) { const m = /^\d+(\.\d+)?/.exec(src.slice(i)); i += m[0].length; push("num", Number(m[0]), start); continue; }
          const id = /^[\p{L}\p{Extended_Pictographic}_][\p{L}\p{N}\p{Extended_Pictographic}_-]*/u.exec(src.slice(i));
          if (id) { i += id[0].length; push("id", id[0], start); continue; }
          const op = ["=>", "!=", "==", "<=", ">=", "&&", "||"].find((o) => src.startsWith(o, i));
          if (op) { i += 2; push("op", op, start); continue; }
          if ("+-*/%<>=!()[]{},.:#".includes(c)) { i++; push("op", c, start); continue; }
          throw new DqlError(`看不懂的字元「${c}」`);
        }
        tokens.push({ type: "eof", value: null, start: src.length, end: src.length });
        return tokens;
      }

      function parseExpression(src) {
        const tokens = tokenize(src); let p = 0;
        const peek = (o = 0) => tokens[p + o];
        const isOp = (v, o = 0) => peek(o).type === "op" && peek(o).value === v;
        const isWord = (w, o = 0) => peek(o).type === "id" && peek(o).value.toLowerCase() === w;
        const expect = (v) => { if (!isOp(v)) throw new DqlError(`這裡應該是「${v}」`); p++; };
        const binary = (next, ops) => () => {
          let left = next();
          for (;;) {
            const t = peek();
            const op = t.type === "op" && ops.includes(t.value) ? t.value : t.type === "id" && ops.includes(t.value.toLowerCase()) ? t.value.toLowerCase() : null;
            if (!op) return left;
            p++; left = { t: "bin", op, l: left, r: next() };
          }
        };
        const unary = () => {
          if (isOp("!")) { p++; return { t: "un", op: "!", e: unary() }; }
          if (isOp("-")) { p++; return { t: "un", op: "-", e: unary() }; }
          return postfix();
        };
        const mul = binary(unary, ["*", "/", "%"]);
        const add = binary(mul, ["+", "-"]);
        const cmpExpr = binary(add, ["=", "==", "!=", "<", ">", "<=", ">="]);
        const and = binary(cmpExpr, ["and", "&&"]);
        const or = binary(and, ["or", "||"]);
        const lambdaAhead = () => {
          if (!isOp("(")) return false;
          let q = 1;
          if (tokens[p + q].type === "op" && tokens[p + q].value === ")") return tokens[p + q + 1].type === "op" && tokens[p + q + 1].value === "=>";
          for (;;) {
            if (tokens[p + q].type !== "id") return false;
            q++;
            if (tokens[p + q].type === "op" && tokens[p + q].value === ",") { q++; continue; }
            return tokens[p + q].type === "op" && tokens[p + q].value === ")" && tokens[p + q + 1].type === "op" && tokens[p + q + 1].value === "=>";
          }
        };
        function primary() {
          const t = peek();
          if (t.type === "num") { p++; return { t: "lit", v: t.value }; }
          if (t.type === "str") { p++; return { t: "lit", v: t.value }; }
          if (t.type === "link") { p++; const m = /^([^|#]*)(#[^|]*)?(?:\|(.*))?$/.exec(t.value); return { t: "lit", v: new Link(resolve(m[1]) || m[1], m[3], false, m[2]) }; }
          if (isOp("!") && peek(1).type === "link") { p++; const l = peek(); p++; return { t: "lit", v: new Link(resolve(l.value.split("|")[0]) || l.value, undefined, true) }; }
          if (lambdaAhead()) {
            p++; const params = [];
            while (!isOp(")")) { params.push(peek().value); p++; if (isOp(",")) p++; }
            p++; expect("=>");
            return { t: "lambda", params, body: or() };
          }
          if (t.type === "id" && isOp("=>", 1)) { p += 2; return { t: "lambda", params: [t.value], body: or() }; }
          if (isOp("(")) { p++; const e = or(); expect(")"); return e; }
          if (isOp("[")) {
            p++; const items = [];
            while (!isOp("]")) { items.push(or()); if (isOp(",")) p++; else if (!isOp("]")) throw new DqlError("清單中應該用逗號分隔"); }
            p++; return { t: "list", items };
          }
          if (isOp("{")) {
            p++; const entries = [];
            while (!isOp("}")) {
              const k = peek(); if (k.type !== "id" && k.type !== "str") throw new DqlError("物件的鍵應該是名稱或字串"); p++;
              expect(":"); entries.push([k.value, or()]);
              if (isOp(",")) p++;
            }
            p++; return { t: "obj", entries };
          }
          if (t.type === "id") {
            const word = t.value.toLowerCase();
            if (word === "true" || word === "false") { p++; return { t: "lit", v: word === "true" }; }
            if (word === "null") { p++; return { t: "lit", v: null }; }
            // date(today)、date(2026-10-15)、dur(3 days)：括號裡是字面值
            if ((word === "date" || word === "dur") && isOp("(", 1)) {
              const open = peek(1); let depth = 0, q = p + 1;
              for (; q < tokens.length; q++) { const x = tokens[q]; if (x.type === "op" && x.value === "(") depth++; if (x.type === "op" && x.value === ")" && --depth === 0) break; }
              const raw = src.slice(open.end, tokens[q].start).trim();
              const literal = word === "date"
                ? /^(today|now|tomorrow|yesterday|sow|eow|som|eom|soy|eoy|\d{4}-\d{2}(-\d{2})?([T ]\d{2}:\d{2}(:\d{2})?)?)$/i.test(raw)
                : /^-?\d+(\.\d+)?\s*[a-zA-Z一-鿿]/.test(raw);
              if (literal) { p = q + 1; return { t: "lit", v: word === "date" ? parseDate(raw) : parseDuration(raw) }; }
            }
            p++;
            if (word === "this") return { t: "this" };
            if (word === "row") return { t: "row" };
            return { t: "id", name: t.value };
          }
          throw new DqlError(t.type === "eof" ? "運算式不完整" : `這裡不能出現「${t.value}」`);
        }
        function postfix() {
          let e = primary();
          for (;;) {
            if (isOp(".")) { p++; const n = peek(); if (n.type !== "id" && n.type !== "num") throw new DqlError("「.」後面應該是欄位名稱"); p++; e = { t: "field", obj: e, name: String(n.value) }; continue; }
            if (isOp("[")) { p++; const idx = or(); expect("]"); e = { t: "index", obj: e, idx }; continue; }
            if (isOp("(")) {
              p++; const args = [];
              while (!isOp(")")) { args.push(or()); if (isOp(",")) p++; else if (!isOp(")")) throw new DqlError("參數之間應該用逗號分隔"); }
              p++; e = { t: "call", fn: e, args }; continue;
            }
            return e;
          }
        }
        const tree = or();
        if (peek().type !== "eof") throw new DqlError(`多出來的「${src.slice(peek().start)}」`);
        return tree;
      }

      // ================= 求值 =================
      function evaluate(node, ctx) {
        switch (node.t) {
          case "lit": return node.v;
          case "this": return ctx.this;
          case "row": return ctx.row;
          case "id": {
            if (ctx.vars && Object.prototype.hasOwnProperty.call(ctx.vars, node.name)) return ctx.vars[node.name];
            const v = field(ctx.row, node.name);
            if (v != null) return v;
            if (FUNCTIONS[node.name.toLowerCase()]) return { __lambda: true, native: FUNCTIONS[node.name.toLowerCase()] };
            return null;
          }
          case "field": return field(evaluate(node.obj, ctx), node.name);
          case "index": {
            const obj = evaluate(node.obj, ctx), idx = evaluate(node.idx, ctx);
            if (obj == null || idx == null) return null;
            if (isArr(obj) && typeof idx === "number") { const a = arr(obj); const v = a[idx < 0 ? a.length + idx : idx]; return v === undefined ? null : v; }
            if (typeof obj === "string" && typeof idx === "number") return obj[idx] ?? null;
            return field(obj, String(idx));
          }
          case "list": return dvArray(node.items.map((x) => evaluate(x, ctx)));
          case "obj": { const o = {}; for (const [k, v] of node.entries) o[k] = evaluate(v, ctx); return o; }
          case "lambda": return { __lambda: true, params: node.params, body: node.body, ctx };
          case "un": {
            const v = evaluate(node.e, ctx);
            if (node.op === "!") return !truthy(v);
            if (typeof v === "number") return -v;
            if (isDur(v)) return new DvDuration(-v.ms, -v.monthsPart);
            return null;
          }
          case "bin": {
            if (node.op === "and" || node.op === "&&") return truthy(evaluate(node.l, ctx)) && truthy(evaluate(node.r, ctx));
            if (node.op === "or" || node.op === "||") return truthy(evaluate(node.l, ctx)) || truthy(evaluate(node.r, ctx));
            return binary(node.op, evaluate(node.l, ctx), evaluate(node.r, ctx));
          }
          case "call": {
            if (node.fn.t === "id" && !(ctx.vars && node.fn.name in ctx.vars)) {
              const fn = FUNCTIONS[node.fn.name.toLowerCase()];
              if (!fn) throw new DqlError(`沒有「${node.fn.name}」這個函式`);
              return fn(...node.args.map((a) => evaluate(a, ctx)));
            }
            const f = evaluate(node.fn, ctx);
            return call(f, node.args.map((a) => evaluate(a, ctx)));
          }
        }
        throw new DqlError("無法計算的運算式");
      }
      function call(f, args) {
        if (!f || !f.__lambda) throw new DqlError("只能呼叫函式");
        if (f.native) return f.native(...args);
        const vars = Object.assign({}, f.ctx.vars);
        f.params.forEach((name, i) => { vars[name] = args[i] === undefined ? null : args[i]; });
        return evaluate(f.body, Object.assign({}, f.ctx, { vars }));
      }
      const fnOf = (f) => (typeof f === "function" ? f : (...args) => call(f, args));
      function binary(op, a, b) {
        switch (op) {
          case "=": case "==": return equal(a, b);
          case "!=": return !equal(a, b);
          case "<": return cmp(a, b) < 0;
          case ">": return cmp(a, b) > 0;
          case "<=": return cmp(a, b) <= 0;
          case ">=": return cmp(a, b) >= 0;
        }
        if (op === "+") {
          if (typeof a === "string" || typeof b === "string") return (a == null ? "" : textOf(a)) + (b == null ? "" : textOf(b));
          if (a == null || b == null) return null;
          if (isArr(a) && isArr(b)) return dvArray([...arr(a), ...arr(b)]);
          if (isDate(a) && isDur(b)) return addDuration(a, b, 1);
          if (isDur(a) && isDate(b)) return addDuration(b, a, 1);
          if (isDur(a) && isDur(b)) return new DvDuration(a.ms + b.ms, a.monthsPart + b.monthsPart);
          if (typeof a === "number" && typeof b === "number") return a + b;
          return null;
        }
        if (a == null || b == null) return null;
        if (op === "-") {
          if (isDate(a) && isDur(b)) return addDuration(a, b, -1);
          if (isDate(a) && isDate(b)) return new DvDuration(a.ts - b.ts);
          if (isDur(a) && isDur(b)) return new DvDuration(a.ms - b.ms, a.monthsPart - b.monthsPart);
          if (typeof a === "number" && typeof b === "number") return a - b;
          return null;
        }
        if (op === "*") {
          if (typeof a === "number" && typeof b === "number") return a * b;
          if (isDur(a) && typeof b === "number") return new DvDuration(a.ms * b, a.monthsPart * b);
          if (typeof a === "number" && isDur(b)) return new DvDuration(b.ms * a, b.monthsPart * a);
          if (typeof a === "string" && typeof b === "number") return a.repeat(Math.max(0, b));
          return null;
        }
        if (op === "/") {
          if (typeof a === "number" && typeof b === "number") return b === 0 ? null : a / b;
          if (isDur(a) && typeof b === "number") return b === 0 ? null : new DvDuration(a.ms / b, a.monthsPart / b);
          if (isDur(a) && isDur(b)) return Number(b) === 0 ? null : Number(a) / Number(b);
          return null;
        }
        if (op === "%") return typeof a === "number" && typeof b === "number" && b !== 0 ? a % b : null;
        return null;
      }
      function addDuration(date, dur, sign) {
        let d = date.plus({ months: Math.trunc(dur.monthsPart) * sign });
        return new DvDate(d.ts + dur.ms * sign);
      }

      // ================= 函式（Dataview 函式參考） =================
      const vec = (f) => (first, ...rest) => (isArr(first) ? dvArray(arr(first).map((x) => f(x, ...rest))) : f(first, ...rest));
      const str = (v) => (v == null ? "" : textOf(v));
      const regex = (pattern, flags = "") => { try { return new RegExp(pattern, flags); } catch (e) { throw new DqlError("正規表示式錯誤：" + pattern); } };
      const numberFormat = (n) => (Number.isInteger(n) ? String(n) : String(Math.round(n * 1e6) / 1e6));
      const FUNCTIONS = {
        // 建構
        object: (...kv) => { const o = {}; for (let i = 0; i + 1 < kv.length; i += 2) o[str(kv[i])] = kv[i + 1]; return o; },
        list: (...items) => dvArray(items), array: (...items) => dvArray(items),
        date: (v, format) => (isArr(v) ? dvArray(arr(v).map((x) => parseDate(x, format))) : parseDate(v, format)),
        dur: (v) => parseDuration(v),
        number: vec((v) => { if (typeof v === "number") return v; const m = /-?\d+(\.\d+)?/.exec(str(v).replace(/,/g, "")); return m ? Number(m[0]) : null; }),
        string: (v) => str(v),
        link: vec((path, display) => (path == null ? null : path instanceof Link ? (display ? path.withDisplay(display) : path) : new Link(resolve(str(path)) || str(path), display))),
        embed: vec((l, flag = true) => (l instanceof Link ? (flag ? l.toEmbed() : new Link(l.path, l.display, false, l.subpath)) : l == null ? null : new Link(str(l), undefined, !!flag))),
        elink: (url, display) => { const a = document.createElement("a"); a.href = str(url); a.textContent = display != null ? str(display) : str(url); a.className = "external-link"; return a; },
        typeof: (v) => typeOf(v),
        // 數字
        round: vec((n, digits = 0) => (typeof n === "number" ? Math.round(n * 10 ** digits) / 10 ** digits : null)),
        trunc: vec((n) => (typeof n === "number" ? Math.trunc(n) : null)),
        floor: vec((n) => (typeof n === "number" ? Math.floor(n) : null)),
        ceil: vec((n) => (typeof n === "number" ? Math.ceil(n) : null)),
        min: (...args) => { const list = args.length === 1 && isArr(args[0]) ? arr(args[0]) : args; const v = list.filter((x) => x != null); return v.length ? v.reduce((a, b) => (cmp(a, b) <= 0 ? a : b)) : null; },
        max: (...args) => { const list = args.length === 1 && isArr(args[0]) ? arr(args[0]) : args; const v = list.filter((x) => x != null); return v.length ? v.reduce((a, b) => (cmp(a, b) >= 0 ? a : b)) : null; },
        sum: (list) => { const v = arr(list).filter((x) => x != null); if (!v.length) return null; return v.slice(1).reduce((a, b) => binary("+", a, b), v[0]); },
        product: (list) => { const v = arr(list).filter((x) => typeof x === "number"); return v.length ? v.reduce((a, b) => a * b, 1) : null; },
        average: (list) => { const v = arr(list).filter((x) => x != null); if (!v.length) return null; const total = FUNCTIONS.sum(v); return binary("/", total, v.length); },
        mean: (list) => FUNCTIONS.average(list),
        minby: (list, f) => { const v = arr(list); if (!v.length) return null; const g = fnOf(f); return v.reduce((a, b) => (cmp(g(a), g(b)) <= 0 ? a : b)); },
        maxby: (list, f) => { const v = arr(list); if (!v.length) return null; const g = fnOf(f); return v.reduce((a, b) => (cmp(g(a), g(b)) >= 0 ? a : b)); },
        reduce: (list, op) => { const v = arr(list); if (!v.length) return null; const g = typeof op === "string" ? (a, b) => binary(op, a, b) : fnOf(op); return v.slice(1).reduce((a, b) => g(a, b), v[0]); },
        // 清單與物件
        contains: (obj, value) => contains(obj, value, false),
        icontains: (obj, value) => contains(obj, value, true),
        econtains: (obj, value) => (isArr(obj) ? arr(obj).some((x) => equal(x, value)) : typeof obj === "string" ? obj === str(value) : isObj(obj) ? Object.prototype.hasOwnProperty.call(obj, str(value)) : equal(obj, value)),
        containsword: vec((text, word) => (text == null ? false : new RegExp(`(^|[^\\p{L}\\p{N}])${str(word).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}($|[^\\p{L}\\p{N}])`, "iu").test(str(text)))),
        extract: (obj, ...keys) => { const o = {}; for (const k of keys) o[str(k)] = field(obj, str(k)); return o; },
        sort: (list, f) => { const v = [...arr(list)]; const g = f ? fnOf(f) : (x) => x; return dvArray(v.sort((a, b) => cmp(g(a), g(b)))); },
        reverse: (list) => (typeof list === "string" ? [...list].reverse().join("") : dvArray([...arr(list)].reverse())),
        length: (v) => (v == null ? 0 : isArr(v) ? arr(v).length : typeof v === "string" ? v.length : isObj(v) ? Object.keys(v).length : 0),
        nonnull: (...args) => dvArray((args.length === 1 && isArr(args[0]) ? arr(args[0]) : args).filter((x) => x != null)),
        firstvalue: (list) => { const v = arr(list).find((x) => x != null); return v === undefined ? null : v; },
        all: (...args) => quantifier(args, (v, g) => v.every(g)),
        any: (...args) => quantifier(args, (v, g) => v.some(g)),
        none: (...args) => quantifier(args, (v, g) => !v.some(g)),
        join: (list, sep = ", ") => (list == null ? "" : isArr(list) ? arr(list).map(str).join(str(sep)) : str(list)),
        filter: (list, f) => dvArray(arr(list).filter((x) => truthy(fnOf(f)(x)))),
        map: (list, f) => dvArray(arr(list).map((x) => fnOf(f)(x))),
        flat: (list, depth = 1) => { const go = (v, d) => v.flatMap((x) => (isArr(x) && d > 0 ? go(arr(x), d - 1) : [x])); return dvArray(go(arr(list), depth)); },
        slice: (list, start = 0, end) => (typeof list === "string" ? list.slice(start, end ?? undefined) : dvArray(arr(list).slice(start, end ?? undefined))),
        unique: (list) => { const seen = new Set(); return dvArray(arr(list).filter((x) => { const k = groupKey(x); if (seen.has(k)) return false; seen.add(k); return true; })); },
        // 文字
        regextest: (pattern, text) => (text == null ? false : regex(str(pattern)).test(str(text))),
        regexmatch: (pattern, text) => (text == null ? false : regex("^(?:" + str(pattern) + ")$").test(str(text))),
        regexreplace: vec((text, pattern, replacement) => (text == null ? null : str(text).replace(regex(str(pattern), "g"), str(replacement)))),
        replace: vec((text, pattern, replacement) => (text == null ? null : str(text).split(str(pattern)).join(str(replacement)))),
        lower: vec((t) => (t == null ? null : str(t).toLowerCase())),
        upper: vec((t) => (t == null ? null : str(t).toUpperCase())),
        split: (text, delimiter, limit) => (text == null ? null : dvArray(str(text).split(regex(str(delimiter))).slice(0, limit == null ? undefined : limit))),
        startswith: vec((t, prefix) => (t == null ? false : str(t).startsWith(str(prefix)))),
        endswith: vec((t, suffix) => (t == null ? false : str(t).endsWith(str(suffix)))),
        padleft: vec((t, len, pad = " ") => str(t).padStart(len, str(pad))),
        padright: vec((t, len, pad = " ") => str(t).padEnd(len, str(pad))),
        substring: vec((t, start, end) => (t == null ? null : str(t).substring(start, end ?? undefined))),
        truncate: vec((t, len, suffix = "...") => { const s = str(t); return s.length > len ? s.slice(0, Math.max(0, len - str(suffix).length)) + str(suffix) : s; }),
        // 其他
        default: (v, fallback) => (isArr(v) ? dvArray(arr(v).map((x) => (x == null ? fallback : x))) : v == null ? fallback : v),
        ldefault: (v, fallback) => (v == null ? fallback : v),
        choice: (cond, a, b) => (truthy(cond) ? a : b),
        striptime: vec((d) => (isDate(d) ? d.startOf("day") : null)),
        dateformat: vec((d, format) => (isDate(d) ? d.toFormat(str(format)) : null)),
        durationformat: (d, format) => {
          if (!isDur(d)) return null;
          let rest = Math.abs(d.valueOf()); const units = { y: 365.25 * DAY, M: 30.44 * DAY, w: 7 * DAY, d: DAY, h: 36e5, m: 6e4, s: 1e3 };
          return str(format).replace(/'([^']*)'|y|M|w|d|h|m|s/g, (t, lit) => { if (lit !== undefined) return lit; const n = Math.floor(rest / units[t]); rest -= n * units[t]; return String(n); });
        },
        currencyformat: (n, currency = "TWD") => (typeof n === "number" ? new Intl.NumberFormat("zh-TW", { style: "currency", currency: str(currency) }).format(n) : null),
        localtime: (d) => d,
        meta: (l) => (l instanceof Link ? { display: l.display ?? null, embed: !!l.embed, path: l.path, subpath: l.subpath ? l.subpath.replace(/^#\^?/, "") : null, type: l.subpath ? (l.subpath.startsWith("#^") ? "block" : "header") : "file" } : null),
        display: (v) => textOf(v),
        hash: (seed, text, variant) => { let h = 2166136261; for (const c of str(seed) + str(text) + str(variant)) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619); } return Math.abs(h); },
        tolower: (t) => FUNCTIONS.lower(t),
      };
      function contains(obj, value, insensitive) {
        if (obj == null) return false;
        const fold = (s) => (insensitive ? s.toLowerCase() : s);
        if (typeof obj === "string") return value != null && fold(obj).includes(fold(str(value)));
        if (isArr(obj)) return arr(obj).some((x) => (typeof x === "string" && typeof value === "string" ? fold(x).includes(fold(value)) : equal(x, value) || (insensitive && contains(x, value, true))));
        if (obj instanceof Link) return value instanceof Link ? equal(obj, value) : fold(obj.path).includes(fold(str(value)));
        if (isObj(obj)) return Object.prototype.hasOwnProperty.call(obj, str(value));
        return equal(obj, value);
      }
      function quantifier(args, test) {
        if (args.length >= 2 && args[args.length - 1] && args[args.length - 1].__lambda && isArr(args[0])) { const g = fnOf(args[args.length - 1]); return test(arr(args[0]), (x) => truthy(g(x))); }
        const list = args.length === 1 && isArr(args[0]) ? arr(args[0]) : args;
        return test(list, truthy);
      }

      // ================= 待辦的欄位（[due:: 2026-10-20]、📅 2026-10-20） =================
      const EMOJI = { "📅": "due", "🗓": "due", "⏳": "scheduled", "🛫": "start", "✅": "completion", "➕": "created" };
      function taskRow(task, page) {
        const row = Object.create(page);
        const text = String(task.text || "");
        Object.assign(row, task, { text, visual: text, task: true, real: true, path: page.file.path, link: page.file.link, section: null, file: page.file,
          tags: dvArray([...text.matchAll(/(?:^|\s)(#[\p{L}\p{N}_/-]+)/gu)].map((m) => m[1])), outlinks: dvArray([...text.matchAll(/\[\[([^\]|#]+)/g)].map((m) => new Link(resolve(m[1]) || m[1]))) });
        for (const m of text.matchAll(/[[(]([^[\]():]+?)::\s*([^\])]*)[\])]/g)) row[m[1].trim()] = coerce(m[2]);
        for (const [emoji, key] of Object.entries(EMOJI)) { const m = new RegExp(emoji + "\\uFE0F?\\s*(\\d{4}-\\d{2}-\\d{2})").exec(text); if (m && row[key] === undefined) row[key] = parseDate(m[1]); }
        for (const key of ["due", "scheduled", "start", "completion", "created"]) if (!Object.prototype.hasOwnProperty.call(row, key)) row[key] = null;
        return row;
      }

      // ================= 查詢 =================
      const COMMANDS = ["FROM", "WHERE", "SORT", "GROUP BY", "FLATTEN", "LIMIT"];
      function splitClauses(src) {
        const clauses = []; let depth = 0, quote = null, start = 0, current = null;
        const text = src.replace(/\r/g, "");
        const atWord = (i) => (i === 0 || /\s/.test(text[i - 1]));
        for (let i = 0; i <= text.length; i++) {
          const c = text[i];
          if (i < text.length) {
            if (quote) { if (c === "\\") { i++; continue; } if (c === quote) quote = null; continue; }
            if (c === '"' || c === "'") { quote = c; continue; }
            if ("([{".includes(c)) { depth++; continue; }
            if (")]}".includes(c)) { depth--; continue; }
            if (depth > 0 || !atWord(i)) continue;
            const rest = text.slice(i);
            const kw = COMMANDS.find((k) => new RegExp("^" + k.replace(" ", "\\s+") + "(\\s|$)", "i").test(rest));
            if (!kw) continue;
            clauses.push({ kw: current, body: text.slice(start, i).trim() });
            current = kw; const m = new RegExp("^" + kw.replace(" ", "\\s+"), "i").exec(rest); start = i + m[0].length; i = start - 1;
          } else clauses.push({ kw: current, body: text.slice(start).trim() });
        }
        return clauses;
      }
      // 逗號分隔（不在括號、引號裡的逗號）
      function splitTop(src, sep = ",") {
        const parts = []; let depth = 0, quote = null, start = 0;
        for (let i = 0; i < src.length; i++) {
          const c = src[i];
          if (quote) { if (c === "\\") { i++; continue; } if (c === quote) quote = null; continue; }
          if (c === '"' || c === "'") quote = c;
          else if ("([{".includes(c)) depth++;
          else if (")]}".includes(c)) depth--;
          else if (c === sep && depth === 0) { parts.push(src.slice(start, i)); start = i + 1; }
        }
        parts.push(src.slice(start));
        return parts.map((x) => x.trim()).filter(Boolean);
      }
      function parseQuery(source) {
        const clauses = splitClauses(source.trim());
        const head = clauses.shift();
        const hm = /^(TABLE|LIST|TASK|CALENDAR)\b\s*([\s\S]*)$/i.exec(head.body);
        if (!hm) throw new DqlError("查詢要以 TABLE、LIST、TASK 或 CALENDAR 開頭");
        const query = { type: hm[1].toLowerCase(), withoutId: false, fields: [], commands: [], source: null };
        let format = hm[2].trim();
        if (/^WITHOUT\s+ID\b/i.test(format)) { query.withoutId = true; format = format.replace(/^WITHOUT\s+ID\s*/i, ""); }
        if (query.type === "table") {
          for (const part of splitTop(format)) {
            const m = /^([\s\S]*?)\s+AS\s+("([^"]*)"|'([^']*)'|([\p{L}\p{N}_ -]+))$/iu.exec(part);
            const expr = m ? m[1] : part;
            query.fields.push({ name: m ? (m[3] ?? m[4] ?? m[5]).trim() : expr.trim(), expr: parseExpression(expr) });
          }
        } else if (query.type === "list" && format) query.fields.push({ name: format, expr: parseExpression(format) });
        else if (query.type === "calendar") { if (!format) throw new DqlError("CALENDAR 後面要指定日期欄位，例如 CALENDAR file.ctime"); query.fields.push({ name: format, expr: parseExpression(format) }); }
        for (const clause of clauses) {
          const body = clause.body;
          switch (clause.kw) {
            case "FROM": query.source = body; break;
            case "WHERE": query.commands.push({ type: "where", expr: parseExpression(body) }); break;
            case "SORT": query.commands.push({ type: "sort", keys: splitTop(body).map((part) => { const m = /^([\s\S]*?)\s+(ASC|ASCENDING|DESC|DESCENDING)$/i.exec(part); return { expr: parseExpression(m ? m[1] : part), desc: !!(m && /^desc/i.test(m[2])) }; }) }); break;
            case "GROUP BY": { const m = /^([\s\S]*?)\s+AS\s+([\p{L}\p{N}_-]+)$/iu.exec(body); query.commands.push({ type: "group", expr: parseExpression(m ? m[1] : body), name: m ? m[2] : simpleName(m ? m[1] : body) }); break; }
            case "FLATTEN": { const m = /^([\s\S]*?)\s+AS\s+([\p{L}\p{N}_-]+)$/iu.exec(body); query.commands.push({ type: "flatten", expr: parseExpression(m ? m[1] : body), name: m ? m[2] : simpleName(m ? m[1] : body) }); break; }
            case "LIMIT": { const n = Number(body); if (!Number.isFinite(n)) throw new DqlError("LIMIT 後面要是數字"); query.commands.push({ type: "limit", n }); break; }
          }
        }
        return query;
      }
      const simpleName = (text) => text.trim();

      function sourceFilter(source) {
        if (!source) return () => true;
        // 括號與 and／or：交給既有的比對（逐層展開括號）
        const s = source.trim();
        const inner = /^\(([\s\S]*)\)$/.exec(s);
        if (inner && balanced(inner[1])) return sourceFilter(inner[1]);
        const orParts = splitWord(s, "or");
        if (orParts.length > 1) { const fs = orParts.map(sourceFilter); return (p) => fs.some((f) => f(p)); }
        const andParts = splitWord(s, "and");
        if (andParts.length > 1) { const fs = andParts.map(sourceFilter); return (p) => fs.every((f) => f(p)); }
        if (/^[-!]\s*\(/.test(s)) { const f = sourceFilter(s.replace(/^[-!]\s*/, "")); return (p) => !f(p); }
        return sourceMatcher(s);
      }
      function balanced(s) { let d = 0; for (const c of s) { if (c === "(") d++; if (c === ")" && --d < 0) return false; } return d === 0; }
      function splitWord(s, word) {
        const parts = []; let depth = 0, quote = null, start = 0;
        for (let i = 0; i < s.length; i++) {
          const c = s[i];
          if (quote) { if (c === quote) quote = null; continue; }
          if (c === '"' || c === "'") { quote = c; continue; }
          if (c === "(" || c === "[") depth++;
          else if (c === ")" || c === "]") depth--;
          else if (depth === 0 && /\s/.test(c)) {
            const m = new RegExp("^\\s+" + word + "\\s+", "i").exec(s.slice(i));
            if (m) { parts.push(s.slice(start, i)); start = i + m[0].length; i = start - 1; }
          }
        }
        parts.push(s.slice(start));
        return parts.map((x) => x.trim()).filter(Boolean);
      }

      function runQuery(source, thisPage) {
        const query = parseQuery(source);
        const pages = I.pages().filter(sourceFilter(query.source));
        const self = thisPage || dv.current();
        let rows = query.type === "task" ? pages.flatMap((p) => arr(p.file.tasks).map((t) => taskRow(t, p))) : pages.slice();
        let grouped = false, groupName = null;
        const ctx = (row) => ({ row, this: self, vars: null });
        for (const command of query.commands) {
          if (command.type === "where") rows = rows.filter((r) => truthy(evaluate(command.expr, ctx(r))));
          else if (command.type === "sort") {
            const keyed = rows.map((r) => ({ r, keys: command.keys.map((k) => evaluate(k.expr, ctx(r))) }));
            keyed.sort((a, b) => { for (let i = 0; i < command.keys.length; i++) { const c = cmp(a.keys[i], b.keys[i]); if (c) return command.keys[i].desc ? -c : c; } return 0; });
            rows = keyed.map((x) => x.r);
          } else if (command.type === "group") {
            const groups = new Map();
            for (const r of rows) { const key = evaluate(command.expr, ctx(r)); const id = groupKey(key); if (!groups.has(id)) groups.set(id, { key, rows: [] }); groups.get(id).rows.push(r); }
            rows = [...groups.values()].sort((a, b) => cmp(a.key, b.key)).map((g) => { const row = { key: g.key, rows: dvArray(g.rows) }; row[command.name] = g.key; return row; });
            grouped = true; groupName = command.name;
          } else if (command.type === "flatten") {
            rows = rows.flatMap((r) => {
              const v = evaluate(command.expr, ctx(r));
              const items = isArr(v) ? arr(v) : [v];
              return (items.length ? items : [null]).map((item) => { const copy = Object.create(Object.getPrototypeOf(r) === Object.prototype ? r : r); Object.assign(copy, r); copy[command.name] = item; return copy; });
            });
          } else if (command.type === "limit") rows = rows.slice(0, command.n);
        }
        return { query, rows, grouped, groupName, self, ctx };
      }

      // 結果轉成 dv.query 的格式
      function queryValue(result) {
        const { query, rows, grouped, groupName, ctx } = result;
        const id = (r) => (grouped ? r.key : r.file ? r.file.link : null);
        if (query.type === "table") {
          const headers = [...(query.withoutId ? [] : [grouped ? groupName || "Group" : "File"]), ...query.fields.map((f) => f.name)];
          const values = rows.map((r) => [...(query.withoutId ? [] : [id(r)]), ...query.fields.map((f) => evaluate(f.expr, ctx(r)))]);
          return { type: "table", headers, values, idMeaning: { type: grouped ? "group" : "path" } };
        }
        if (query.type === "list") {
          const values = rows.map((r) => {
            const v = query.fields.length ? evaluate(query.fields[0].expr, ctx(r)) : null;
            if (query.withoutId) return query.fields.length ? v : id(r);
            return query.fields.length ? { primary: id(r), value: v } : id(r);
          });
          return { type: "list", values, grouped, rows };
        }
        if (query.type === "task") return { type: "task", values: rows, grouped, groupName };
        return { type: "calendar", values: rows.map((r) => ({ date: parseDate(evaluate(query.fields[0].expr, ctx(r))), link: r.file ? r.file.link : null, value: r })) };
      }

      // ================= 顯示 =================
      function renderTable(container, value) {
        const wrap = container.createDiv({ cls: "dv-table-wrap" });
        const table = wrap.createEl("table", { cls: ["dataview", "table-view-table"] });
        const head = table.createEl("thead").createEl("tr");
        value.headers.forEach((h, i) => { const th = head.createEl("th"); th.textContent = h; if (i === 0 && value.idMeaning && value.headers.length && value.values.length) th.createSpan({ cls: "dataview small-text", text: ` (${value.values.length})` }); });
        const body = table.createEl("tbody");
        for (const row of value.values) { const tr = body.createEl("tr"); for (const cell of row) renderValue(cell, tr.createEl("td")); }
        if (!value.values.length) wrap.createDiv({ cls: "dv-empty", text: "沒有結果" }).style.padding = "8px 10px";
      }
      function renderList(container, value) {
        const ul = container.createEl("ul", { cls: ["dataview", "list-view-ul"] });
        if (value.grouped) {
          value.rows.forEach((group, i) => {
            const li = ul.createEl("li"); renderValue(group.key, li.createSpan({ cls: "dv-group" }), true);
            const v = value.values[i];
            if (v && typeof v === "object" && "primary" in v) { if (v.value != null) { li.appendChild(document.createTextNode("：")); renderValue(v.value, li, true); } }
            else { const sub = li.createEl("ul"); for (const r of arr(group.rows)) renderValue(r.file ? r.file.link : r, sub.createEl("li"), true); }
          });
        } else {
          for (const v of value.values) {
            const li = ul.createEl("li", { cls: "dataview-result-list-li" });
            if (v && typeof v === "object" && "primary" in v && !(v instanceof Link)) { renderValue(v.primary, li, true); if (v.value != null) { li.appendChild(document.createTextNode("："));  renderValue(v.value, li, true); } }
            else renderValue(v, li, true);
          }
        }
        if (!value.values.length) container.createDiv({ cls: "dv-empty", text: "沒有結果" });
      }
      function renderTasks(container, value) {
        const draw = (parent, tasks) => {
          const ul = parent.createEl("ul", { cls: "contains-task-list" });
          for (const t of tasks) {
            const li = ul.createEl("li", { cls: ["task-list-item", t.completed ? "is-checked" : ""].filter(Boolean) });
            const box = li.createEl("input", { type: "checkbox" }); box.checked = !!t.completed;
            box.addEventListener("change", async () => {
              box.disabled = true;
              try { await bridge("toggleTask", { path: t.path, text: t.text, done: box.checked }); t.completed = box.checked; li.classList.toggle("is-checked", box.checked); }
              catch (e) { box.checked = !box.checked; new window.Notice("無法更新待辦：" + (e && e.message ? e.message : e)); }
              box.disabled = false;
            });
            renderValue(t.text, li, true);
          }
        };
        const tasks = value.values;
        if (!tasks.length) { container.createDiv({ cls: "dv-empty", text: "沒有待辦" }); return; }
        if (value.grouped) { for (const g of tasks) { const h = container.createEl("h4"); renderValue(g.key, h, true); draw(container, arr(g.rows)); } return; }
        const byFile = new Map();
        for (const t of tasks) { if (!byFile.has(t.path)) byFile.set(t.path, []); byFile.get(t.path).push(t); }
        for (const [path, list] of byFile) { const h = container.createEl("h4"); renderValue(new Link(path), h, true); h.createSpan({ cls: "dataview small-text", text: ` (${list.length})` }); draw(container, list); }
      }
      function renderCalendar(container, value) {
        const entries = value.values.filter((e) => e.date);
        let month = new DvDate(new Date()).startOf("month");
        const box = container.createDiv({ cls: "dv-calendar" });
        const draw = () => {
          box.empty();
          const bar = box.createDiv({ cls: "dv-cal-bar" });
          const prev = bar.createEl("button", { text: "‹" }), title = bar.createEl("strong", { text: month.toFormat("yyyy 年 M 月") }), next = bar.createEl("button", { text: "›" });
          void title;
          prev.addEventListener("click", () => { month = month.minus({ months: 1 }); draw(); I.scheduleHeight(); });
          next.addEventListener("click", () => { month = month.plus({ months: 1 }); draw(); I.scheduleHeight(); });
          const grid = box.createDiv({ cls: "dv-cal-grid" });
          for (const w of ["一", "二", "三", "四", "五", "六", "日"]) grid.createDiv({ cls: "dv-cal-head", text: w });
          const first = month.weekday; for (let i = 1; i < first; i++) grid.createDiv();
          const days = month.endOf("month").day;
          for (let d = 1; d <= days; d++) {
            const cell = grid.createDiv({ cls: "dv-cal-day" }); cell.createDiv({ cls: "dv-cal-num", text: String(d) });
            const day = month.plus({ days: d - 1 });
            for (const e of entries.filter((x) => x.date.hasSame(day, "day"))) { const dot = cell.createDiv({ cls: "dv-cal-item" }); renderValue(e.link, dot, true); }
          }
        };
        draw();
      }
      function renderResult(container, value) {
        if (value.type === "table") renderTable(container, value);
        else if (value.type === "list") renderList(container, value);
        else if (value.type === "task") renderTasks(container, value);
        else renderCalendar(container, value);
      }
      const style = document.createElement("style");
      style.textContent = `.dv-calendar{font-size:13px}.dv-cal-bar{display:flex;align-items:center;justify-content:space-between;margin:4px 0 8px}.dv-cal-bar button{padding:2px 12px}
      .dv-cal-grid{display:grid;grid-template-columns:repeat(7,1fr);gap:2px}.dv-cal-head{text-align:center;color:var(--text-muted);font-size:12px;padding:2px 0}
      .dv-cal-day{min-height:52px;border:1px solid var(--background-modifier-border);border-radius:6px;padding:2px 3px;overflow:hidden}.dv-cal-num{color:var(--text-muted);font-size:11px}
      .dv-cal-item{font-size:11px;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.dv-group{font-weight:600}`;
      document.head.appendChild(style);

      // ================= dv 的查詢 API =================
      dv.execute = async (source) => { const result = runQuery(String(source)); renderResult(dv.container, queryValue(result)); I.scheduleHeight(); };
      dv.query = async (source, originFile) => { try { const r = runQuery(String(source), originFile ? I.pageFor(originFile) : undefined); return { successful: true, value: queryValue(r) }; } catch (e) { return { successful: false, error: String(e.message || e) }; } };
      dv.tryQuery = async (source, originFile) => { const r = await dv.query(source, originFile); if (!r.successful) throw new Error(r.error); return r.value; };
      dv.queryMarkdown = async (source, originFile) => {
        const r = await dv.query(source, originFile); if (!r.successful) return r;
        const v = r.value; const md = (x) => (x instanceof Link ? x.toString() : textOf(x));
        if (v.type === "table") return { successful: true, value: dv.markdownTable(v.headers, v.values.map((row) => row.map(md))) };
        if (v.type === "list") return { successful: true, value: v.values.map((x) => "- " + (x && x.primary !== undefined ? md(x.primary) + (x.value != null ? "：" + md(x.value) : "") : md(x))).join("\n") };
        if (v.type === "task") return { successful: true, value: arr(v.values).map((t) => `- [${t.completed ? "x" : " "}] ${t.text}`).join("\n") };
        return { successful: true, value: "" };
      };
      dv.tryQueryMarkdown = async (source, originFile) => { const r = await dv.queryMarkdown(source, originFile); if (!r.successful) throw new Error(r.error); return r.value; };
      dv.evaluate = (expression, context = {}) => { try { const row = Object.assign(Object.create(dv.current()), context); return { successful: true, value: evaluate(parseExpression(String(expression)), { row, this: dv.current(), vars: null }) }; } catch (e) { return { successful: false, error: String(e.message || e) }; } };
      dv.tryEvaluate = (expression, context) => { const r = dv.evaluate(expression, context); if (!r.successful) throw new Error(r.error); return r.value; };
      dv.duration = (v) => parseDuration(v);
      dv.date = (v) => parseDate(v);

      // ================= 行內查詢（`= 運算式`、`$= JavaScript`） =================
      const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
      window.__dvEvaluate = async (items) => {
        const self = dv.current();
        const out = [];
        for (const item of items) {
          try {
            if (item.kind === "dql") { const v = evaluate(parseExpression(item.code), { row: self, this: self, vars: null }); out.push(v == null ? "—" : textOf(v)); }
            else {
              let v;
              try { v = await new AsyncFunction("dv", "input", "return (" + item.code + ");")(dv, undefined); }
              catch (syntax) { if (!(syntax instanceof SyntaxError)) throw syntax; v = await new AsyncFunction("dv", "input", item.code)(dv, undefined); }
              out.push(v == null ? "—" : v instanceof Node ? v.textContent : textOf(v));
            }
          } catch (e) { out.push("⚠︎ " + String(e && e.message ? e.message : e)); }
        }
        return out;
      };
      window.__dvQuery = { parseQuery, parseExpression, evaluate, runQuery, queryValue, parseDate, parseDuration, truthy, equal };
    })();
    """##
}
