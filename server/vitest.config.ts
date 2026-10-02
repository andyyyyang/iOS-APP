import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    env: { NODE_ENV: "test" },
    // A shared Postgres database (TEST_DATABASE_URL) cannot be used by parallel test files.
    fileParallelism: !process.env.TEST_DATABASE_URL,
  },
});
