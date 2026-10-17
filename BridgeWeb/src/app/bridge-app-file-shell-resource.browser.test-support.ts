import { lazy, type LazyExoticComponent } from 'react';
import { afterEach, beforeEach } from 'vitest';

import { BridgeTestFactRecorder } from '../../tests/test-support/bridge-test-fact-recorder.js';
import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import type { BridgeFileViewerShell } from '../file-viewer/bridge-file-viewer-shell.js';

type FileShellModule = { readonly default: typeof BridgeFileViewerShell };

const activeResources = new Set<() => void>();

function retireFileShellResources(): void {
	for (const close of activeResources) close();
	activeResources.clear();
}

beforeEach((context): void => {
	context.signal.addEventListener('abort', retireFileShellResources, { once: true });
	context.onTestFinished((): void => {
		retireFileShellResources();
		context.signal.removeEventListener('abort', retireFileShellResources);
	});
});

afterEach(retireFileShellResources);

/** Observe the exact lazy loader promise, including its module-to-component mapping. */
export function createFileShellResource(holdResolution = false): {
	readonly component: LazyExoticComponent<typeof BridgeFileViewerShell>;
	readonly started: Promise<void>;
	readonly release: () => void;
	readonly completed: () => Promise<FileShellModule>;
	readonly hasStarted: () => boolean;
	readonly awaited: Promise<void>;
} {
	const facts = new BridgeTestFactRecorder<'started' | 'awaited'>();
	const release = createBridgeProductDeferred<void>();
	let isClosed = false;
	activeResources.add((): void => {
		isClosed = true;
		facts.close(new Error('File shell resource test owner retired.'));
		release.resolve();
	});
	const observe = (kind: 'started' | 'awaited', label: string): Promise<void> => {
		const observation = facts.waitFor((fact): boolean => fact === kind, label).then((): void => {});
		void observation.catch((): void => {});
		return observation;
	};
	let loading: Promise<FileShellModule> | null = null;
	if (!holdResolution) release.resolve();
	const component = lazy((): Promise<FileShellModule> => {
		loading = release.promise.then(async (): Promise<FileShellModule> => {
			const module = await import('../file-viewer/bridge-file-viewer-shell.js');
			return { default: module.BridgeFileViewerShell };
		});
		facts.record('started');
		return loading;
	});
	return {
		component,
		get started(): Promise<void> {
			return observe('started', 'File shell lazy loader started');
		},
		hasStarted: (): boolean => loading !== null,
		get awaited(): Promise<void> {
			return observe('awaited', 'File shell completion owner awaited loader');
		},
		release: (): void => release.resolve(),
		completed: async (): Promise<FileShellModule> => {
			// Teardown still joins the real loader after the observation source retires.
			if (!isClosed) {
				facts.record('awaited');
				await observe('started', 'File shell lazy loader started');
			}
			if (loading === null) throw new Error('File shell loader did not start.');
			return await loading;
		},
	};
}
