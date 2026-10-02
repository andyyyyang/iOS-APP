// Shared data types for the LocalOCR REST API (see docs/API.md).
// This file must not import "obsidian" so that it can be unit-tested.

export interface Classification {
	templateId?: string | null;
	confidence?: number | null;
	provider?: string | null;
	probabilities?: Record<string, number> | null;
}

export interface Scan {
	id: string;
	createdAt: string;
	updatedAt: string;
	source?: string | null;
	text?: string | null;
	templateId?: string | null;
	classification?: Classification | null;
	data?: unknown;
	lineCount?: number | null;
	averageConfidence?: number | null;
	pageCount?: number | null;
	device?: string | null;
}

export interface Template {
	id: string;
	name: string;
	description?: string;
	keywords?: string[];
	sample?: unknown;
	instructions?: string | null;
	version?: number;
	updatedAt?: string;
}

export interface ScanPage {
	items: Scan[];
	nextCursor: string | null;
}

export interface HealthResponse {
	status: string;
	version?: string;
	database?: string;
	jev?: boolean;
}

/** Incremental-sync bookkeeping persisted in plugin data. */
export interface SyncCursorState {
	/** Opaque cursor returned by the server; sent back as-is. */
	cursor: string | null;
	/** `updatedAfter` query value. Kept fixed while following cursors. */
	updatedAfter: string | null;
	/** `updatedAt` of the newest scan seen so far (items arrive ascending). */
	lastSeenUpdatedAt: string | null;
}

export type WriteOutcome = "created" | "updated" | "unchanged";
