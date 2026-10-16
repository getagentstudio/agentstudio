import { afterEach, beforeEach, expect, test, vi } from 'vitest';

import type { BridgePaneFailedStartFact } from '../models/bridge-pane-failed-start.js';
import { createBridgePaneRuntime, type BridgePaneSessionPort } from './bridge-pane-runtime.js';

beforeEach((): void => {
	vi.stubGlobal('cancelAnimationFrame', vi.fn());
	vi.stubGlobal(
		'requestAnimationFrame',
		vi.fn((): number => 1),
	);
});
afterEach((): void => {
	vi.unstubAllGlobals();
});

test('pre-E3 exhaustion publishes one typed failed-start fact and replays the terminal fact to App', (): void => {
	const exhaustionPort: { trigger: (() => void) | null } = { trigger: null };
	const session = {
		createDispatcher: () => ({ dispatch: (): void => {}, dispose: (): void => {} }),
		dispose: (): void => {},
		installNativeBootstrap: (): void => {},
		setReplacementBootstrapExhaustionHandler: (handler: () => void): void => {
			exhaustionPort.trigger = handler;
		},
	} satisfies BridgePaneSessionPort;
	const runtime = createBridgePaneRuntime({ sessionFactory: () => session });
	const facts: BridgePaneFailedStartFact[] = [];
	try {
		runtime.setPaneFailedStartHandler((fact): void => {
			facts.push(fact);
		});
		const trigger = exhaustionPort.trigger;
		if (trigger === null) throw new Error('Expected the existing bootstrap exhaustion boundary.');
		trigger();
		trigger();
		expect(facts).toEqual([{ kind: 'failedStart', cause: 'bootstrapBudgetExhausted' }]);
		const replay: BridgePaneFailedStartFact[] = [];
		runtime.setPaneFailedStartHandler((fact): void => {
			replay.push(fact);
		});
		expect(replay).toEqual(facts);
		expect(
			runtime.surfaceClient('review').renderStore.getViewRecoveryStatus('review.metadata'),
		).toBeNull();
	} finally {
		runtime.dispose();
	}
});
