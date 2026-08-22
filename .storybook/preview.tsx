import type { Preview } from "@storybook/react-vite";
import "../src/renderer/styles.css";

const preview: Preview = {
  parameters: {
    actions: { argTypesRegex: "^on[A-Z].*" },
    // Component stories must fail on accessibility regressions instead of
    // recording a deferred check that can silently pass in CI.
    a11y: { test: "error" },
    backgrounds: { disable: true },
  },
  decorators: [(Story) => <div style={{ minHeight: "100vh", padding: 32, background: "var(--ss-color-canvas)" }}><Story /></div>],
};

export default preview;
