import { MemoryStore } from "./memory.js";
import { PostgresStore } from "./postgres.js";
import type { Store } from "./types.js";

export type { Store } from "./types.js";
export { MemoryStore } from "./memory.js";
export { PostgresStore } from "./postgres.js";

/** Postgres when DATABASE_URL is set, otherwise a non-persistent in-memory store. */
export function createStore(databaseUrl: string | undefined): Store {
  return databaseUrl ? new PostgresStore(databaseUrl) : new MemoryStore();
}
