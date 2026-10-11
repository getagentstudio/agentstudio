import type { TestContext } from 'vitest';
import { VitestTestRunner } from 'vitest/runners';

import { finishBridgeWebE2ETest } from './bridge-web-e2e-test-retirement.ts';

export default class BridgeWebE2ERunner extends VitestTestRunner {
	async onTaskFinished(task: Pick<TestContext['task'], 'id' | 'result'>): Promise<void> {
		// Vitest awaits this outside its detached test-function wrapper and before
		// afterEach/onTestFinished or dispatching the next sequential test.
		await finishBridgeWebE2ETest(task.id, task.result?.state === 'fail');
	}
}
