import { test } from 'vitest';

import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

test('stuck Chromium is retired by the runner', async (context) => {
	await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
		const launch = await BridgeWebTestLaunch.start({ signal: context.signal });
		const executablePath = process.env['BRIDGE_STUB_BROWSER'];
		if (executablePath === undefined) throw new Error('Missing browser fixture');
		await launch.launchBrowser({ executablePath, headless: true });
	});
});
test('the next test runs', (): void => {
	process.stdout.write('CHROMIUM_NEXT_TEST_RAN\n');
});
