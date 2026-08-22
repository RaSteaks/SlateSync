import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/refactor/**/*.test.ts", "test/refactor/**/*.test.tsx"],
    exclude: ["**/node_modules/**", "**/dist/**", "**/out/**"],
    passWithNoTests: false,
    reporters: ["dot"],
  },
});
