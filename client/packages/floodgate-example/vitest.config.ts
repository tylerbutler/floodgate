import { defineConfig, mergeConfig } from "vitest/config";

import defaultConfig from "../../vitest.config";

const config = mergeConfig(defaultConfig, defineConfig({}));

// biome-ignore lint/style/noDefaultExport: correct pattern for config files
export default config;
