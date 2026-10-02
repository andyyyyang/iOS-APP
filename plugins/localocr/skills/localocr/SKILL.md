---
name: localocr
description: Work with scans from the LocalOCR iPhone app through the localocr MCP server — list and search scanned documents, read their OCR text and structured JSON, classify text into scenarios with Jev, create or update scenario templates (the JSON output formats), validate JSON against a template, and write structured data back. Use when the user mentions LocalOCR, scanned receipts/business cards/documents, scan history, OCR results, scenario templates, or wants scans turned into JSON in a specific format.
---

# LocalOCR

The LocalOCR iPhone app recognizes text on device (Apple Vision), detects the document's scenario, and fills the scenario's JSON template with Apple Foundation Models. Results are uploaded to the user's own LocalOCR server, which this plugin connects to over MCP (`localocr` server).

## Concepts

- **Scan**: one scanned document — `id`, `createdAt`, `source`, `text` (OCR), `templateId`, `classification` (`provider`: `jev`, `on-device`, `keywords`, `manual`), `data` (JSON in the template's shape, may be `null`).
- **Template (scenario)**: `id`, `name`, `description` (used for classification), `keywords`, `sample` (an example JSON object — output must have the same keys, nesting and key order), `instructions`.
  Built-ins: `receipt`, `business_card`, `event`, `document` (fallback).

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

## Workflows

**Fill in missing JSON** (scans with `data: null`, e.g. from devices without Apple Intelligence):
1. `list_scans`, pick scans whose `data` is null.
2. `get_scan` for the text; if `templateId` is null, call `classify_text`.
3. `get_template`, then produce JSON with exactly the sample's keys and order. Use only facts present in the text; use `null` for anything missing. Numbers as numbers, dates `YYYY-MM-DD`, times `HH:mm` unless the template says otherwise.
4. `validate_data`; fix every issue, then `update_scan_data`.

**Add a new scenario** when the user describes a new document type or desired format:
1. Draft `id` (lowercase, `a-z0-9_-`), `name`, a specific `description`, `keywords`, a realistic `sample` object in the user's desired shape, and `instructions`.
2. `upsert_template`. The iPhone app picks it up on its next template sync, and Jev starts classifying into it immediately.

**Report or export**: use `list_scans` with `templateId` (e.g. `receipt`) and `updatedAfter`, read `data`, then summarize (totals per store, contacts list, upcoming events) or convert to CSV/Markdown as asked.

## Notes

- Never invent values that are not in the OCR text.
- Keep template `sample` key order — it defines the output order everywhere (app, Obsidian notes, harnesses).
- Scan text can contain personal data; only quote what the user needs.
