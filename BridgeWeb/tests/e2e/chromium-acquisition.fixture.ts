import { expect, test } from 'vitest';

import { startOwnedBridgeDevelopmentServer } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { createStuckChromiumFixture } from '../../scripts/dev-server/bridge-web-chromium-test-support.ts';
import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import {
	handleLaunchPromise,
	type HandledLaunchPromise,
} from '../../scripts/dev-server/handled-launch-promise.ts';
import {
	startOwnedBridgeWebBrowserHost,
	type OwnedBridgeWebBrowserHost,
} from '../../scripts/dev-server/owned-bridge-web-browser-host.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

let stub: Awaited<ReturnType<typeof createStuckChromiumFixture>> | undefined;
let launch: BridgeWebTestLaunch | undefined;
let acquisition: HandledLaunchPromise<unknown> | undefined;
let browserHost: OwnedBridgeWebBrowserHost | undefined;

test('stuck Chromium is retired by the runner', async (context) => {
	await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
		stub = await createStuckChromiumFixture();
		launch = await BridgeWebTestLaunch.start(
			{ signal: context.signal },
			{
				startBackend: startOwnedBridgeDevelopmentServer,
				startBrowserHost: async (props): Promise<OwnedBridgeWebBrowserHost> =>
					await startOwnedBridgeWebBrowserHost({
						...props,
						onSpawn: (host): void => {
							browserHost = host;
							props.onSpawn?.(host);
						},
					}),
			},
		);
		acquisition = handleLaunchPromise(
			launch.launchBrowser({ executablePath: stub.executablePath, headless: true }),
			'runner fixture Chromium acquisition',
		);
		const pid = await Promise.race([
			stub.ready,
			acquisition.value().then((): never => {
				throw new Error('Stuck browser unexpectedly completed acquisition');
			}),
		]);
		process.stdout.write(`CHROMIUM_STUB_READY pid=${pid}\n`);
		// Fail only once the real subprocess is stuck in its protocol handshake.
		// The custom runner, rather than this body, must join launch retirement.
		throw new Error('CHROMIUM_FIXTURE_FAILURE_AFTER_READY');
	});
});
test('the next test runs after acquisition and process retirement', async () => {
	if (
		stub === undefined ||
		launch === undefined ||
		acquisition === undefined ||
		browserHost === undefined
	)
		throw new Error('Missing stuck Chromium acquisition');
	try {
		// onTaskFinished has already joined disposal. A pending acquisition or a
		// surviving FIFO writer must prevent the continuation proof from passing.
		expect(launch.cleanup.dataRootRemoved).toBe(true);
		expect(launch.cleanup.failures).toEqual([]);
		const outcome = await acquisition.settled;
		expect(outcome.kind).toBe('failed');
		await browserHost.whenExited;
		await stub.eof;
		process.stdout.write(
			'CHROMIUM_RUNNER_RETIRED acquisition=settled stubFIFO=EOF rootRemoved=true\n',
		);
		process.stdout.write('CHROMIUM_NEXT_TEST_RAN\n');
	} finally {
		await stub.reap();
	}
});
