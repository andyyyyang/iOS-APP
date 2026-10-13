import { randomBytes } from "node:crypto";
import { AppError } from "../errors.js";
import { pairingClaimSchema, pairingCreateSchema } from "../schemas.js";
import { parse } from "./parse.js";

/** No 0/O, 1/I: easy to read aloud and type. 32 symbols, so `byte % 32` stays uniform. */
export const PAIRING_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export const PAIRING_CODE_LENGTH = 8;
export const PAIRING_TTL_MS = 10 * 60 * 1000;
/** Outstanding codes per API key; creating more drops the oldest. */
export const MAX_PAIRING_CODES_PER_KEY = 20;

export interface PairingCode {
  /** "XXXX-XXXX" */
  code: string;
  expiresAt: string;
}

export interface PairingClaim {
  apiKey: string;
  vaultName: string | null;
  notesFolder: string | null;
}

interface PendingPairing extends PairingClaim {
  expiresAt: number;
}

export interface PairingServiceOptions {
  /** Milliseconds since the epoch (injectable for tests). */
  now?: () => number;
  /** n random bytes (injectable for tests). */
  random?: (size: number) => Uint8Array;
}

/** Uppercase, without spaces or hyphens: "abcd efgh", "ABCD-EFGH" and "ABCDEFGH" are the same code. */
export const normalizePairingCode = (code: string) => code.toUpperCase().replace(/[\s-]+/g, "");

const invalidCode = () => new AppError(404, "invalid_code", "Invalid or expired pairing code");

/**
 * Single-use pairing codes that hand the creating device's API key to a new device (iPhone/iPad app).
 * Kept in memory: the server runs as a single replica and a code lives only 10 minutes.
 */
export class PairingService {
  /** Normalized code → pending pairing, in creation order (Map keeps insertion order). */
  private readonly pending = new Map<string, PendingPairing>();
  private readonly now: () => number;
  private readonly random: (size: number) => Uint8Array;

  constructor({ now = Date.now, random = randomBytes }: PairingServiceOptions = {}) {
    this.now = now;
    this.random = random;
  }

  /** Number of unexpired codes (for tests). */
  get size(): number {
    this.prune();
    return this.pending.size;
  }

  /** Creates a code for `apiKey`, the key that authenticated the request. */
  create(apiKey: string, body: unknown): PairingCode {
    const input = parse(pairingCreateSchema, body ?? {});
    this.prune();

    const mine = [...this.pending].filter(([, entry]) => entry.apiKey === apiKey);
    for (const [code] of mine.slice(0, Math.max(0, mine.length - MAX_PAIRING_CODES_PER_KEY + 1))) {
      this.pending.delete(code);
    }

    let code = this.generate();
    while (this.pending.has(code)) code = this.generate();
    const expiresAt = this.now() + PAIRING_TTL_MS;
    this.pending.set(code, {
      apiKey,
      vaultName: input.vaultName ?? null,
      notesFolder: input.notesFolder ?? null,
      expiresAt,
    });
    return { code: `${code.slice(0, 4)}-${code.slice(4)}`, expiresAt: new Date(expiresAt).toISOString() };
  }

  /** Redeems a code once. Unknown, expired and already used codes all fail with the same 404 invalid_code. */
  claim(body: unknown): PairingClaim {
    const { code } = parse(pairingClaimSchema, body ?? {});
    this.prune();
    const key = normalizePairingCode(code);
    const entry = this.pending.get(key);
    if (!entry) throw invalidCode();
    this.pending.delete(key);
    return { apiKey: entry.apiKey, vaultName: entry.vaultName, notesFolder: entry.notesFolder };
  }

  private generate(): string {
    const bytes = this.random(PAIRING_CODE_LENGTH);
    let code = "";
    for (let i = 0; i < PAIRING_CODE_LENGTH; i++) code += PAIRING_ALPHABET[bytes[i]! % PAIRING_ALPHABET.length];
    return code;
  }

  private prune(): void {
    const now = this.now();
    for (const [code, entry] of this.pending) {
      if (entry.expiresAt <= now) this.pending.delete(code);
    }
  }
}
