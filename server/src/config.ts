export interface Config {
  port: number;
  nodeEnv: string;
  databaseUrl: string | undefined;
  /** Empty only when auth is explicitly disabled (tests / ALLOW_NO_AUTH=1). */
  apiKeys: string[];
  jevApiKey: string | undefined;
  jevModel: string;
  /** S3-compatible bucket holding the Obsidian vault; null unless endpoint, bucket and both keys are set. */
  vault: VaultConfig | null;
  /** Public base URL (PUBLIC_URL, no trailing slash) for pairing links; undefined = derived from each request. */
  publicUrl: string | undefined;
  /** GITHUB_TOKEN: optional, only raises the GitHub API rate limit when mirroring plugin releases. Never logged. */
  githubToken: string | undefined;
  /** ANTHROPIC_API_KEY: enables cloud AI runs (/v1/assistant/runs). Never logged. */
  anthropicApiKey: string | undefined;
  /** ASSISTANT_MODEL (default claude-opus-5-5). */
  assistantModel: string;
  /** ASSISTANT_MAX_TURNS: model calls per run (default 40). */
  assistantMaxTurns: number;
  /** ASSISTANT_CODE_EXECUTION: Anthropic's code-execution sandbox (default on; "0" disables). */
  assistantCodeExecution: boolean;
  /** ASSISTANT_WEB_SEARCH: Anthropic's web search (default off). */
  assistantWebSearch: boolean;
}

export interface VaultConfig {
  endpoint: string;
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  forcePathStyle: boolean;
  /** Key prefix in front of every vault path ("" or ending with "/"), like Remotely Save's remote prefix. */
  prefix: string;
}

const nonEmpty = (value: string | undefined) => {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
};

const VAULT_REQUIRED = [
  "VAULT_S3_ENDPOINT",
  "VAULT_S3_BUCKET",
  "VAULT_S3_ACCESS_KEY_ID",
  "VAULT_S3_SECRET_ACCESS_KEY",
] as const;

const isTrue = (value: string | undefined) => ["1", "true", "yes", "on"].includes(value?.trim().toLowerCase() ?? "");

/** Reads VAULT_* variables. Only variable names are ever logged, never their values. */
export function parseVaultConfig(env: NodeJS.ProcessEnv, logger: Pick<Console, "warn"> = console): VaultConfig | null {
  const prefix = nonEmpty(env.VAULT_PREFIX) ?? "";
  if (prefix && (!prefix.endsWith("/") || prefix.startsWith("/"))) {
    throw new Error(`Invalid VAULT_PREFIX: must end with "/" and must not start with "/" (got "${prefix}")`);
  }

  const [endpoint, bucket, accessKeyId, secretAccessKey] = VAULT_REQUIRED.map((name) => nonEmpty(env[name]));
  if (!endpoint || !bucket || !accessKeyId || !secretAccessKey) {
    const missing = VAULT_REQUIRED.filter((name) => !nonEmpty(env[name]));
    if (missing.length < VAULT_REQUIRED.length) {
      logger.warn(`[config] WARNING: vault storage disabled; missing ${missing.join(", ")}`);
    }
    return null;
  }
  return {
    endpoint,
    bucket,
    region: nonEmpty(env.VAULT_S3_REGION) ?? "auto",
    accessKeyId,
    secretAccessKey,
    forcePathStyle: isTrue(env.VAULT_S3_FORCE_PATH_STYLE),
    prefix,
  };
}

/** PUBLIC_URL without trailing slashes; must be an http(s) URL. */
export function parsePublicUrl(raw: string | undefined): string | undefined {
  const value = nonEmpty(raw)?.replace(/\/+$/, "");
  if (!value) return undefined;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`Invalid PUBLIC_URL: ${value}`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error(`Invalid PUBLIC_URL: ${value}`);
  return value;
}

const isFalse = (value: string | undefined) => ["0", "false", "no", "off"].includes(value?.trim().toLowerCase() ?? "");

/** ASSISTANT_MAX_TURNS: a positive integer, default 40. */
export function parseMaxTurns(raw: string | undefined): number {
  const value = nonEmpty(raw);
  if (value === undefined) return 40;
  const turns = Number(value);
  if (!Number.isInteger(turns) || turns < 1 || turns > 1000) throw new Error(`Invalid ASSISTANT_MAX_TURNS: ${value}`);
  return turns;
}

export function parseApiKeys(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((key) => key.trim())
    .filter(Boolean);
}

export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
  logger: Pick<Console, "warn"> = console,
): Config {
  const nodeEnv = env.NODE_ENV ?? "development";
  const port = Number.parseInt(env.PORT ?? "3000", 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid PORT: ${env.PORT}`);
  }

  const apiKeys = parseApiKeys(env.API_KEYS);
  if (apiKeys.length === 0) {
    const allowed = nodeEnv === "test" || env.ALLOW_NO_AUTH === "1";
    if (!allowed) {
      throw new Error(
        "API_KEYS is empty. Set API_KEYS (comma-separated) or ALLOW_NO_AUTH=1 for local development.",
      );
    }
    logger.warn("[config] WARNING: API_KEYS is empty; all endpoints are unauthenticated.");
  }

  return {
    port,
    nodeEnv,
    databaseUrl: nonEmpty(env.DATABASE_URL),
    apiKeys,
    jevApiKey: nonEmpty(env.JEV_API_KEY) ?? nonEmpty(env.TYPESAFE_API_KEY),
    jevModel: nonEmpty(env.JEV_MODEL) ?? "jev-latest",
    vault: parseVaultConfig(env, logger),
    publicUrl: parsePublicUrl(env.PUBLIC_URL),
    githubToken: nonEmpty(env.GITHUB_TOKEN),
    anthropicApiKey: nonEmpty(env.ANTHROPIC_API_KEY),
    assistantModel: nonEmpty(env.ASSISTANT_MODEL) ?? "claude-opus-5-5",
    assistantMaxTurns: parseMaxTurns(env.ASSISTANT_MAX_TURNS),
    assistantCodeExecution: !isFalse(env.ASSISTANT_CODE_EXECUTION),
    assistantWebSearch: isTrue(env.ASSISTANT_WEB_SEARCH),
  };
}
