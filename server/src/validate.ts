import type { JsonValue, ValidationIssue, ValidationResult } from "./types.js";

type Kind = "string" | "number" | "boolean" | "array" | "object" | "null";

function kindOf(value: unknown): Kind {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  switch (typeof value) {
    case "string":
      return "string";
    case "number":
      return "number";
    case "boolean":
      return "boolean";
    default:
      return "object";
  }
}

const IDENTIFIER = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const childPath = (path: string, key: string) =>
  IDENTIFIER.test(key) ? `${path}.${key}` : `${path}[${JSON.stringify(key)}]`;

/**
 * Structurally validates `data` against a template `sample`:
 * - objects must have exactly the sample's keys (missing and unexpected keys are reported);
 * - leaf types must match; `null` in data is always allowed; `null` in the sample means "string or null";
 * - arrays are checked element-wise against the sample's first element (an empty sample array allows anything).
 */
export function validateAgainstSample(data: unknown, sample: JsonValue): ValidationResult {
  const issues: ValidationIssue[] = [];
  check(data, sample, "$", issues);
  return { valid: issues.length === 0, issues };
}

function check(data: unknown, sample: JsonValue, path: string, issues: ValidationIssue[]): void {
  if (data === null) return;

  const expected: Kind = sample === null ? "string" : kindOf(sample);
  const actual = kindOf(data);
  if (actual !== expected) {
    issues.push({ path, message: `Expected ${expected}${sample === null ? " or null" : ""}, got ${actual}` });
    return;
  }

  if (Array.isArray(sample)) {
    const element = sample[0];
    if (element === undefined) return;
    (data as unknown[]).forEach((item, index) => check(item, element, `${path}[${index}]`, issues));
    return;
  }

  if (expected === "object") {
    const sampleObject = sample as Record<string, JsonValue>;
    const dataObject = data as Record<string, unknown>;
    for (const [key, sampleValue] of Object.entries(sampleObject)) {
      if (!Object.hasOwn(dataObject, key)) {
        issues.push({ path: childPath(path, key), message: "Missing key" });
        continue;
      }
      check(dataObject[key], sampleValue, childPath(path, key), issues);
    }
    for (const key of Object.keys(dataObject)) {
      if (!Object.hasOwn(sampleObject, key)) {
        issues.push({ path: childPath(path, key), message: "Unexpected key (not in template sample)" });
      }
    }
  }
}
