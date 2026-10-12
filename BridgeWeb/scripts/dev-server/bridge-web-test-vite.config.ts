import { defineConfig, mergeConfig } from 'vite';

import productConfiguration from '../../vite.config.ts';

// Only the harness child selects this configuration. Product builds and the
// interactive loop continue to use vite.config.ts directly.
export default defineConfig(async (environment) => {
	const configuration = await productConfiguration(environment);
	if (process.env['BRIDGE_WEB_TEST_RESPONSE_FACTS'] !== '1') return configuration;
	const { createBridgeWebViteResponseFactPlugin } =
		await import('./bridge-web-vite-response-fact-plugin.ts');
	return mergeConfig(configuration, { plugins: [createBridgeWebViteResponseFactPlugin()] });
});
