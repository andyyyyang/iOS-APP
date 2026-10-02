import type { Express } from "express";
import pg from "pg";
import { afterEach } from "vitest";
import { bootstrapStore } from "../src/bootstrap.js";
import type { ClassificationCandidate, Classifier, ClassifierResult } from "../src/classifier/types.js";
import { createApp } from "../src/http/app.js";
import { MemoryStore } from "../src/store/memory.js";
import { PostgresStore } from "../src/store/postgres.js";
import type { Store } from "../src/store/types.js";

/** Set TEST_DATABASE_URL to run the whole suite against a real (disposable!) Postgres database. */
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const openStores: Store[] = [];

afterEach(async () => {
  await Promise.all(openStores.splice(0).map((store) => store.close()));
});

async function createTestStore(): Promise<Store> {
  if (!TEST_DATABASE_URL) return new MemoryStore();
  const client = new pg.Client({ connectionString: TEST_DATABASE_URL });
  await client.connect();
  await client.query("DROP TABLE IF EXISTS scans, templates, write_clock, schema_migrations");
  await client.end();
  const store = new PostgresStore(TEST_DATABASE_URL);
  openStores.push(store);
  return store;
}

export const API_KEY = "test-key-123";
export const AUTH = { Authorization: `Bearer ${API_KEY}` };
const silent = { info() {} };

export class FakeClassifier implements Classifier {
  readonly provider = "jev";
  readonly calls: { text: string; candidates: ClassificationCandidate[] }[] = [];

  constructor(private readonly respond?: (candidates: ClassificationCandidate[]) => ClassifierResult) {}

  async classify(text: string, candidates: ClassificationCandidate[]): Promise<ClassifierResult> {
    this.calls.push({ text, candidates });
    if (this.respond) return this.respond(candidates);
    const probabilities = Object.fromEntries(candidates.map((c, i) => [c.id, i === 0 ? 0.9 : 0.1 / (candidates.length - 1)]));
    return { templateId: candidates[0]!.id, confidence: 0.9, probabilities, provider: this.provider };
  }
}

export async function setup(options: { classifier?: Classifier | null; apiKeys?: string[] } = {}): Promise<{
  app: Express;
  store: Store;
}> {
  const store = await createTestStore();
  await bootstrapStore(store, silent);
  const app = createApp({
    store,
    classifier: options.classifier ?? null,
    apiKeys: options.apiKeys ?? [API_KEY],
  });
  return { app, store };
}

export const randomScanId = () => crypto.randomUUID().toUpperCase();

export function scanBody(overrides: Record<string, unknown> = {}) {
  return {
    createdAt: "2026-10-02T03:10:00.000Z",
    source: "camera",
    text: "全聯福利中心\n鮮乳 45\n合計 45",
    templateId: "receipt",
    classification: {
      templateId: "receipt",
      confidence: 0.93,
      provider: "jev",
      probabilities: { receipt: 0.93, document: 0.05, business_card: 0.02 },
    },
    data: { store: "全聯福利中心", date: null, items: [{ name: "鮮乳", quantity: 1, price: 45 }], total: 45, currency: "TWD" },
    lineCount: 3,
    averageConfidence: 0.91,
    pageCount: 1,
    device: "iPhone",
    ...overrides,
  };
}
