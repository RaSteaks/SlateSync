import type { StorybookConfig } from "@storybook/react-vite";

const config: StorybookConfig = {
  stories: ["../src/**/*.stories.@(ts|tsx)"],
  addons: ["@storybook/addon-a11y"],
  framework: { name: "@storybook/react-vite", options: {} },
  // Storybook 10 enables generated docs through each story meta's
  // `autodocs` tag; the former `docs.autodocs` config no longer exists.
};

export default config;
