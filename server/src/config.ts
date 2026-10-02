export interface Config {
  port: number;
  nodeEnv: string;
  databaseUrl: string | undefined;
  /** Empty only when auth is explicitly disabled (tests / ALLOW_NO_AUTH=1). */
  apiKeys: string[];
  jevApiKey: string | undefined;
  jevModel: string;
}

const nonEmpty = (value: string | undefined) => {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
};

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
  };
}
