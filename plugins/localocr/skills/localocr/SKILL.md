---
name: localocr
description: Work with the user's LocalOCR data through the localocr MCP server — scans from the iPhone app (OCR text, scenario JSON, templates, Jev classification) and the user's Obsidian vault (list, search, read and write Markdown notes, including handwritten iPad notebooks). Use when the user mentions LocalOCR, scanned receipts/business cards/documents/FV60 invoices, scan history, OCR results, scenario templates, their Obsidian notes or vault, iPad handwritten notes, or wants scans turned into JSON in a specific format.
---

# LocalOCR

The LocalOCR iPhone/iPad app recognizes text on device (Apple Vision), detects the document's scenario, and fills the scenario's JSON template with Apple Foundation Models. Results are uploaded to the user's own LocalOCR server, which this plugin connects to over MCP (`localocr` server).

The server also holds the user's **Obsidian vault** as plain files in a Railway bucket, synced to Obsidian on their Mac/iPhone/iPad by the Remotely Save plugin. iPad handwritten notebooks land in `iPad 筆記/<title>.md` (frontmatter, AI summary callout, key points, to-dos, recognized handwriting, embedded page images `![[nb-xxxx-p1.png]]`); their page images and re-editable notebook archives (`.localocr-notebook`) live in `iPad 筆記/附件/`.

## Concepts

- **Scan**: one scanned document — `id`, `createdAt`, `source`, `text` (OCR), `templateId`, `classification` (`provider`: `jev`, `on-device`, `keywords`, `manual`), `data` (JSON in the template's shape, may be `null`).
- **Template (scenario)**: `id`, `name`, `description` (used for classification), `keywords` (a `!` prefix marks a strong signal — e.g. a vendor's tax ID or company name — that decides the scenario on its own when only one template matches), `sample` (an example JSON object — output must have the same keys, nesting and key order), `instructions`, `rules`.
  Built-ins: `receipt`, `business_card`, `event`, `document` (fallback). Repo-managed: `fv60_air` (FV60 air-freight vendor invoice, 萬泰物流) and `fv60_sea` (FV60 sea-freight claim from 義佳 with three companies' invoices).
- **Rules**: deterministic post-processing applied after extraction, in order (`value`, `copy`, `template` with `{field}` / `{field:,}` for thousands separators, `sum`, `join`, `divide` (fields or numbers) + `round`, `match` (regex over the whole OCR text, unique matches joined by `separator`; capture groups are concatenated), `today`, `generate: base36time`, `lookup` + `table`, `onlyIfEmpty`). When you fill `data` yourself, read the template's rules and apply them too (e.g. FV60 `amount` = invoice total incl. tax (sea: sum of `taxItems[].taxBase` + `taxAmount`), `expenseAmount` = sea: amount ÷ 1.05 rounded, air: same as amount, `price` = amount ÷ qty rounded to 3 decimals, `caseNo` = every JT number in the text such as `JT2609240` or `JT2609240-1` joined with `,`, `text` = `出口/{osat}/{caseNo}`). Rules targeting `_title` / `_subtitle` only name the record in the app (e.g. JT number; total and unit price) and are not part of `data`. Field targets of rules are not printed on the document. Sample keys starting with `_` are helper inputs for rules (e.g. FV60 `_declarationQuantities` = quantities of each line on the export customs declaration 報單, summed into `qty`); they are removed from the final `data`.

## Tools

| Tool | Use it to |
| --- | --- |
| `list_scans` | Browse or search scans (`query`, `templateId`, `updatedAfter`, `limit`) |
| `get_scan` | Read one scan's full text and JSON |
| `update_scan_data` | Write structured `data` (and optionally `templateId`) back to a scan |
| `list_templates` / `get_template` | See available scenarios and their JSON formats |
| `upsert_template` | Add a new scenario or change an output format |
| `delete_template` | Remove a scenario |
| `classify_text` | Ask Jev which scenario a text belongs to |
| `validate_data` | Check that JSON matches a template before saving it |
| `vault_list` | List vault files/folders (`prefix`, `recursive`) |
| `vault_search` | Full-text search over the vault's Markdown notes (`query`, `prefix`, `limit`) |
| `vault_read` | Read a note (returns its text and `etag`) |
| `vault_write` | Create or update a note (`path`, `content`, `ifMatch` from `vault_read`, `createOnly`) |

## Workflows

**Fill in missing JSON** (scans with `data: null`, e.g. from devices without Apple Intelligence):
1. `list_scans`, pick scans whose `data` is null.
2. `get_scan` for the text; if `templateId` is null, call `classify_text`.
3. `get_template`, then produce JSON with exactly the sample's keys and order. Use only facts present in the text; use `null` for anything missing. Numbers as numbers, dates `YYYY-MM-DD`, times `HH:mm` unless the template says otherwise.
4. `validate_data`; fix every issue, then `update_scan_data`.

**Add a new scenario** when the user describes a new document type or desired format:
1. Draft `id` (lowercase, `a-z0-9_-`), `name`, a specific `description`, `keywords` (prefix text unique to this scenario's documents with `!`, e.g. `"!22368445"`), a realistic `sample` object in the user's desired shape, and `instructions`.
2. `upsert_template`. The iPhone app picks it up on its next template sync, and Jev starts classifying into it immediately.

**Work with Obsidian notes**:
1. Find notes with `vault_search` (content) or `vault_list` (folders). Paths are vault-relative, e.g. `11 SOP/fv60-廠商請款-紀錄.json`.
2. `vault_read` before changing a note; keep its frontmatter and existing content, change only what the user asked.
3. `vault_write` with `ifMatch` set to the etag you read. On a precondition failure the note changed in the meantime — read it again and redo the edit. Without `ifMatch` the tool only creates new notes (an existing file returns `precondition_failed` with its `currentEtag`), so you must read a note before replacing it.
4. Changes reach Obsidian on the next Remotely Save sync (on open, on save, or every few minutes).

**Report or export**: use `list_scans` with `templateId` (e.g. `receipt`) and `updatedAfter`, read `data`, then summarize (totals per store, contacts list, upcoming events) or convert to CSV/Markdown as asked.

## Notes

- Never invent values that are not in the OCR text.
- Keep template `sample` key order — it defines the output order everywhere (app, Obsidian notes, harnesses).
- Scan text and notes can contain personal data; only quote what the user needs.
- Never delete or mass-rewrite vault notes; there is no version history on the bucket.
