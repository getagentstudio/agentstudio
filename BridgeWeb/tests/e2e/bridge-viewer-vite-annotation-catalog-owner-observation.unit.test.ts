import { runInNewContext } from 'node:vm';

import { expect, test } from 'vitest';

import type { BridgeWorkerAnnotationCatalogStagingEvent } from '../../src/core/comm-worker/bridge-worker-annotation-contracts.js';
import { WorktreeAnnotationProjectionStore } from '../../src/worktree-annotations/worktree-annotation-projection-store.js';
import {
	annotationCatalogOwnerObservationScript,
	installAnnotationCatalogFailureObservation,
} from './bridge-viewer-vite-annotation-catalog-owner-observation.ts';

async function observeCatalog(): Promise<{
	readonly store: WorktreeAnnotationProjectionStore;
	readonly wait: () => Promise<unknown>;
	readonly retire: () => void;
	readonly publishWorker: (state: string) => void;
	readonly publishMessage: (message: unknown) => void;
	readonly observerCount: () => number;
}> {
	// Only the browser module loader and DOM are stand-ins. Catalog staging,
	// validation, revision publication and the serialized wait run real code.
	class ObservedProjectionStore extends WorktreeAnnotationProjectionStore {}
	const workerObservers = new Set<(snapshot: { readonly state: string }) => void>();
	const windowTarget = new EventTarget();
	let workerState = 'ready';
	let documentObserverCount = 0;
	const ports: EventTarget[] = [];
	const context = {
		storeModule: { WorktreeAnnotationProjectionStore: ObservedProjectionStore },
		externalDiagnostics: {
			readBridgeReviewSelectionDiagnostic: (): { readonly sessionState: string } => ({
				sessionState: workerState,
			}),
			observeBridgePaneCommWorkerSessionDiagnosticSnapshots: (
				listener: (snapshot: { readonly state: string }) => void,
			): (() => void) => {
				workerObservers.add(listener);
				return (): void => {
					workerObservers.delete(listener);
				};
			},
		},
		window: windowTarget,
		document: { querySelector: (): null => null },
		Event,
		MessageChannel: class {
			readonly port2 = new EventTarget();
			constructor() {
				ports.push(this.port2);
			}
		},
		MutationObserver: class {
			observe(): void {
				documentObserverCount += 1;
			}
			disconnect(): void {
				documentObserverCount -= 1;
			}
		},
	};
	const installFailure: unknown = runInNewContext(
		`(${installAnnotationCatalogFailureObservation.toString()})(); new MessageChannel();`,
		context,
	);
	void installFailure;
	let script = annotationCatalogOwnerObservationScript('main-store');
	// Native import is preserved in production; replace only its two loader expressions.
	script = script
		.replace('await import("main-store")', 'await storeModule')
		.replace(
			"await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href)",
			'await externalDiagnostics',
		);
	const installation: unknown = runInNewContext(script, context);
	await installation;
	const wait: unknown = Reflect.get(context, '__bridgeAwaitAnnotationCatalogCommit');
	if (typeof wait !== 'function') throw new Error('Catalog waiter not installed.');
	return {
		store: new ObservedProjectionStore(),
		wait: async (): Promise<unknown> => await Reflect.apply(wait, context, []),
		retire: (): void => {
			windowTarget.dispatchEvent(new Event('pagehide'));
		},
		publishWorker: (state): void => {
			workerState = state;
			for (const listener of workerObservers) listener({ state });
		},
		publishMessage: (message): void => {
			for (const port of ports) port.dispatchEvent(new MessageEvent('message', { data: message }));
		},
		observerCount: (): number => documentObserverCount + workerObservers.size,
	};
}

function staging(
	phase: 'catalog.begin' | 'catalog.commit',
	surface: 'fileView' | 'review' = 'review',
): BridgeWorkerAnnotationCatalogStagingEvent {
	return {
		authority: {
			subscriptionId: 'catalog-subscription',
			workerDerivationEpoch: 1,
			worktreeId: 'worktree-1',
		},
		direction: 'serverWorkerToMain',
		kind: 'annotationCatalogStaging',
		surface,
		transfer:
			phase === 'catalog.begin'
				? { kind: phase, catalogRevision: 7, expectedEntryCount: 0, transferId: 'catalog-transfer' }
				: {
						kind: phase,
						catalogRevision: 7,
						entryCount: 0,
						windowCount: 0,
						transferId: 'catalog-transfer',
					},
		transferDescriptors: [],
		wireVersion: 1,
	};
}

test('waits through staging and resolves the real Main catalog revision after a delayed commit', async () => {
	const observation = await observeCatalog();
	const outcome = observation.wait();
	try {
		observation.store.applyCatalogStaging(staging('catalog.begin'));
		expect(observation.observerCount()).toBe(2);
		observation.store.applyCatalogStaging(staging('catalog.commit'));
		observation.retire();
		await expect(outcome).resolves.toBe(7);
		expect(observation.observerCount()).toBe(0);
	} finally {
		observation.retire();
		await Promise.allSettled([outcome]);
	}
});

test('reads an already committed catalog without waiting for another publication', async () => {
	const observation = await observeCatalog();
	observation.store.applyCatalogStaging(staging('catalog.begin'));
	observation.store.applyCatalogStaging(staging('catalog.commit'));
	const outcome = observation.wait();
	observation.retire();
	await expect(outcome).resolves.toBe(7);
	expect(observation.observerCount()).toBe(0);
});

test.each(['fileView', 'rejected-review'] as const)(
	'does not accept a %s transfer as the Review Main commit',
	async (source) => {
		const observation = await observeCatalog();
		const outcome = observation.wait();
		const assertion = expect(outcome).rejects.toThrow('document-retired');
		if (source === 'fileView')
			observation.store.applyCatalogStaging(staging('catalog.begin', 'fileView'));
		observation.store.applyCatalogStaging(
			staging('catalog.commit', source === 'fileView' ? 'fileView' : 'review'),
		);
		observation.retire();
		await assertion;
		expect(observation.observerCount()).toBe(0);
	},
);

test('worker replacement remains pending and exhaustion closes the catalog wait', async () => {
	const observation = await observeCatalog();
	const outcome = observation.wait();
	const assertion = expect(outcome).rejects.toThrow('worker-recovery-exhausted');
	try {
		observation.publishWorker('replacement_requested');
		expect(observation.observerCount()).toBe(2);
		observation.publishWorker('failed');
	} finally {
		observation.retire();
		await assertion;
	}
	expect(observation.observerCount()).toBe(0);
});

test.each([
	{
		message: {
			kind: 'annotationProjectionConvergence',
			surface: 'review',
			state: { kind: 'unavailable', retryable: false, catalogAuthorityRetired: false },
		},
		reason: 'annotation-projection-unavailable',
	},
	{
		message: {
			kind: 'viewRecoveryStatus',
			view: { kind: 'review.annotations' },
			status: 'failedRetryable',
		},
		reason: 'annotation-view-recovery-failed',
	},
])('ends on the existing annotation owner failure: $reason', async ({ message, reason }) => {
	const observation = await observeCatalog();
	const outcome = observation.wait();
	const assertion = expect(outcome).rejects.toThrow(reason);
	try {
		observation.publishMessage(message);
	} finally {
		observation.retire();
		await assertion;
	}
	expect(observation.observerCount()).toBe(0);
});

test('retired subscription recovery remains pending until a validated commit', async () => {
	const observation = await observeCatalog();
	const outcome = observation.wait();
	try {
		observation.publishMessage({
			kind: 'annotationProjectionConvergence',
			surface: 'review',
			state: { kind: 'unavailable', retryable: true, catalogAuthorityRetired: true },
		});
		observation.store.applyCatalogStaging(staging('catalog.begin'));
		observation.store.applyCatalogStaging(staging('catalog.commit'));
		observation.retire();
		await expect(outcome).resolves.toBe(7);
	} finally {
		observation.retire();
		await Promise.allSettled([outcome]);
	}
});

test('an exhausted retryable query ends without waiting for page retirement', async () => {
	const observation = await observeCatalog();
	const outcome = observation.wait();
	const assertion = expect(outcome).rejects.toThrow('annotation-projection-unavailable');
	try {
		observation.publishMessage({
			kind: 'annotationProjectionConvergence',
			surface: 'review',
			state: { kind: 'unavailable', retryable: true, catalogAuthorityRetired: false },
		});
	} finally {
		observation.retire();
		await assertion;
	}
	expect(observation.observerCount()).toBe(0);
});

test('worker disposal retires the catalog producer', async () => {
	const observation = await observeCatalog();
	const outcome = observation.wait();
	const assertion = expect(outcome).rejects.toThrow('worker-session-disposed');
	try {
		observation.publishWorker('disposed');
	} finally {
		observation.retire();
		await assertion;
	}
	expect(observation.observerCount()).toBe(0);
});
