import { lazy, type LazyExoticComponent } from 'react';

import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import type { BridgeFileViewerShell } from '../file-viewer/bridge-file-viewer-shell.js';

type FileShellModule = { readonly default: typeof BridgeFileViewerShell };

/** Observe the exact lazy loader promise, including its module-to-component mapping. */
export function createFileShellResource(holdResolution = false): {
	readonly component: LazyExoticComponent<typeof BridgeFileViewerShell>;
	readonly started: Promise<void>;
	readonly release: () => void;
	readonly completed: () => Promise<FileShellModule>;
	readonly hasStarted: () => boolean;
	readonly awaited: Promise<void>;
} {
	const started = createBridgeProductDeferred<void>();
	const release = createBridgeProductDeferred<void>();
	const awaited = createBridgeProductDeferred<void>();
	let loading: Promise<FileShellModule> | null = null;
	if (!holdResolution) release.resolve();
	const component = lazy((): Promise<FileShellModule> => {
		loading = release.promise.then(async (): Promise<FileShellModule> => {
			const module = await import('../file-viewer/bridge-file-viewer-shell.js');
			return { default: module.BridgeFileViewerShell };
		});
		started.resolve();
		return loading;
	});
	return {
		component,
		started: started.promise,
		hasStarted: (): boolean => loading !== null,
		awaited: awaited.promise,
		release: (): void => release.resolve(),
		completed: async (): Promise<FileShellModule> => {
			awaited.resolve();
			await started.promise;
			if (loading === null) throw new Error('File shell loader did not start.');
			return await loading;
		},
	};
}
