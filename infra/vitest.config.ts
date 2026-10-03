import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    // AppSync provides util/extensions at runtime; tests use a stand-in.
    alias: { "@aws-appsync/utils": fileURLToPath(new URL("./test/appsyncUtils.ts", import.meta.url)) },
  },
  test: { testTimeout: 60_000 },
});
