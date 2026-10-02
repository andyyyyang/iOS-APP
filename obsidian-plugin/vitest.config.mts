import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		include: ["test/**/*.test.ts"],
		// File names use local time; pin the zone so tests are deterministic.
		env: { TZ: "Asia/Taipei" },
	},
});
