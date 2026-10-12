import type { Plugin } from 'vite';

import {
	bridgeWebViteResponseFactPrefix,
	type BridgeWebViteResponseCloseFact,
} from './bridge-web-vite-response-facts.ts';

export function createBridgeWebViteResponseFactPlugin(): Plugin {
	let requestSequence = 0;
	return {
		name: 'bridge-web-test-metadata-response-facts',
		enforce: 'pre',
		configureServer(server): void {
			server.middlewares.use((request, response, next): void => {
				const route = request.url;
				if (route?.startsWith('/__bridge-product/stream') === true) {
					requestSequence += 1;
					const fact: BridgeWebViteResponseCloseFact = {
						kind: 'metadata-response-closed',
						requestSequence,
						route,
					};
					response.once('close', (): void => {
						process.stdout.write(`${bridgeWebViteResponseFactPrefix}${JSON.stringify(fact)}\n`);
					});
				}
				next();
			});
		},
	};
}
