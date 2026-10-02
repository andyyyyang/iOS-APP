import { bootstrapStore } from "./bootstrap.js";
import { createClassifier } from "./classifier/index.js";
import { loadConfig } from "./config.js";
import { createApp } from "./http/app.js";
import { createStore } from "./store/index.js";
import { VERSION } from "./version.js";

async function main() {
  const config = loadConfig();
  const store = createStore(config.databaseUrl);
  if (store.kind === "memory") {
    console.warn("[startup] DATABASE_URL is not set; using in-memory storage (data is lost on restart).");
  }
  await bootstrapStore(store);

  const classifier = createClassifier(config);
  const app = createApp({ store, classifier, apiKeys: config.apiKeys });

  const server = app.listen(config.port, "0.0.0.0", () => {
    console.info(
      `[startup] LocalOCR server ${VERSION} listening on 0.0.0.0:${config.port} ` +
        `(database=${store.kind}, classifier=${classifier?.provider ?? "none"})`,
    );
  });

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.info(`[shutdown] ${signal} received; closing`);
    const force = setTimeout(() => process.exit(1), 10_000);
    force.unref();
    server.close(async () => {
      await store.close().catch((error) => console.error("[shutdown] store close failed", error));
      process.exit(0);
    });
    server.closeIdleConnections();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

main().catch((error) => {
  console.error("[startup] fatal:", error instanceof Error ? error.message : error);
  process.exit(1);
});
