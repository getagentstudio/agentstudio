import { afterEach, expect, test, vi } from 'vitest';

import { createBridgePaneRuntime, type BridgePaneSessionPort } from './bridge-pane-runtime.js';

afterEach((): void => {
	vi.unstubAllGlobals();
});

test('surface recovery prepares both consumers through one pane session and cannot revive disposal', () => {
	// Arrange
	vi.stubGlobal('cancelAnimationFrame', vi.fn());
	vi.stubGlobal(
		'requestAnimationFrame',
		vi.fn((): number => 1),
	);
	const requestWorkerReplacement =
		vi.fn<NonNullable<BridgePaneSessionPort['requestWorkerReplacement']>>();
	const session: BridgePaneSessionPort = {
		createDispatcher: () => ({ dispatch: (): void => {}, dispose: (): void => {} }),
		dispose: (): void => {},
		installNativeBootstrap: (): void => {},
		requestWorkerReplacement,
	};
	const runtime = createBridgePaneRuntime({
		recordDiagnosticSnapshot: (): void => {},
		sessionFactory: () => session,
	});
	try {
		const fileClient = runtime.surfaceClient('fileView');
		const reviewClient = runtime.surfaceClient('review');
		const prepareFile = vi.fn();
		const prepareReview = vi.fn();
		fileClient.subscribeWorkerReplacement?.(prepareFile);
		reviewClient.subscribeWorkerReplacement?.(prepareReview);

		// Act
		reviewClient.requestWorkerReplacement('reviewInstalledReceiptFailed');

		// Assert
		expect(prepareFile).toHaveBeenCalledOnce();
		expect(prepareReview).toHaveBeenCalledOnce();
		expect(requestWorkerReplacement).toHaveBeenCalledOnce();
		expect(requestWorkerReplacement).toHaveBeenCalledWith({
			kind: 'runtimeRecovery',
			source: 'reviewInstalledReceiptFailed',
		});
		runtime.dispose();
		fileClient.requestWorkerReplacement('renderDispositionProbeExhausted');
		expect(requestWorkerReplacement).toHaveBeenCalledOnce();
	} finally {
		runtime.dispose();
	}
});
