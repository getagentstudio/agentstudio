import { startOwnedBridgeDevelopmentServer } from './bridge-development-server-process.ts';
import { spawnBrowserHostFixture } from './bridge-web-chromium-host.test-support.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { startOwnedBridgeWebBrowserHost } from './owned-bridge-web-browser-host.ts';

const launch = await BridgeWebTestLaunch.start(
	{},
	{
		startBackend: startOwnedBridgeDevelopmentServer,
		startBrowserHost: async (props) =>
			await startOwnedBridgeWebBrowserHost(
				{
					...props,
					onSpawn: (host): void => {
						props.onSpawn?.(host);
						process.stdout.write(`HOST ${host.pid}\n`);
					},
				},
				{
					spawnChild: () =>
						spawnBrowserHostFixture({ options: props.options, inheritWitness: true }),
				},
			),
	},
);
const executablePath = process.env['BRIDGE_STUB_BROWSER'];
if (executablePath === undefined) throw new Error('Missing browser fixture');
await launch.launchBrowser({ executablePath, headless: true });
