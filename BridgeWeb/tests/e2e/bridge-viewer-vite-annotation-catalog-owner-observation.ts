import type { Page, Response } from 'playwright';

import { reviewWaitTerminalOwner } from './bridge-viewer-vite-review-owner-wait.ts';
import { waitForOwnerOrRetirement } from './bridge-viewer-vite-selected-content-wait.ts';

// Observe the existing owner, after its real staging validation and publication.
export function annotationCatalogOwnerObservationScript(moduleUrl: string): string {
	return `(async () => {
		const { WorktreeAnnotationProjectionStore } = await import(${JSON.stringify(moduleUrl)});
		const diagnostics = await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href);
		const terminalOwner = (${reviewWaitTerminalOwner.toString()});
		const stores = new Set();
		const listeners = new Set();
		const original = WorktreeAnnotationProjectionStore.prototype.applyCatalogStaging;
		WorktreeAnnotationProjectionStore.prototype.applyCatalogStaging = function (...args) {
			const result = original.apply(this, args);
			if (args[0].surface === 'review') {
				stores.add(this);
				for (const listener of listeners) listener();
			}
			return result;
		};
		globalThis.__bridgeAwaitAnnotationCatalogCommit = () => new Promise((resolve, reject) => {
			let ended = false;
			let unsubscribeWorker = () => {};
			let workerSessionState = diagnostics.readBridgeReviewSelectionDiagnostic()?.sessionState ?? null;
			const finish = (error, revision) => {
				if (ended) return;
				ended = true;
				listeners.delete(inspect);
				observer.disconnect(); unsubscribeWorker();
				window.removeEventListener('pagehide', retired);
				window.removeEventListener('__bridge_annotation_catalog_owner_changed', inspect);
				if (error === null) resolve(revision); else reject(error);
			};
			const retired = () => finish(new Error('Main annotation catalog ended: document-retired'));
			const inspect = () => {
				if (ended) return;
				try {
					const terminal = terminalOwner({ inactiveSession: document.querySelector('[data-testid="bridge-dev-session-inactive"]') !== null, workerSessionState });
					const failure = terminal ?? (workerSessionState === 'disposed' ? 'worker-session-disposed' : window.__bridgeAnnotationCatalogOwnerFailure);
					if (failure != null) { finish(new Error('Main annotation catalog ended: ' + failure)); return; }
					if (workerSessionState !== 'ready') return;
					for (const store of stores) {
						const catalog = store.getCatalogSnapshot();
						if (catalog.kind === 'current') { finish(null, catalog.catalog.catalogRevision); return; }
					}
				} catch (error) { finish(error); }
			};
			const observer = new MutationObserver(inspect);
			observer.observe(document, { childList: true, subtree: true });
			listeners.add(inspect);
			window.addEventListener('pagehide', retired, { once: true });
			window.addEventListener('__bridge_annotation_catalog_owner_changed', inspect);
			unsubscribeWorker = diagnostics.observeBridgePaneCommWorkerSessionDiagnosticSnapshots(snapshot => { workerSessionState = snapshot.state; inspect(); });
			if (ended) unsubscribeWorker();
			inspect();
		});
	})()`;
}

export async function observeAnnotationCatalogOwner(page: Page): Promise<{
	readonly install: () => Promise<void>;
}> {
	let moduleUrl: string | null = null;
	const observeResponse = (response: Response): void => {
		if (new URL(response.url()).pathname.endsWith('/worktree-annotation-projection-store.ts')) {
			moduleUrl = response.url();
		}
	};
	page.on('response', observeResponse);
	await page.addInitScript(installAnnotationCatalogFailureObservation);
	return {
		install: async (): Promise<void> => {
			page.off('response', observeResponse);
			if (moduleUrl === null)
				throw new Error('Catalog observer did not see the live Main store module.');
			await page.evaluate(annotationCatalogOwnerObservationScript(moduleUrl));
		},
	};
}

export async function waitForInitialAnnotationCatalogCommit(page: Page): Promise<number> {
	let catalogRevision: number | null = null;
	await waitForOwnerOrRetirement({
		label: 'Main annotation catalog commit',
		subscribeRetirement: (retire): (() => void) => {
			const closed = (): void => retire('page-closed');
			const crashed = (): void => retire('page-crashed');
			page.on('close', closed);
			page.on('crash', crashed);
			if (page.isClosed()) closed();
			return (): void => {
				page.off('close', closed);
				page.off('crash', crashed);
			};
		},
		run: async (): Promise<void> => {
			catalogRevision = await page.evaluate(async (): Promise<number> => {
				const wait: unknown = Reflect.get(globalThis, '__bridgeAwaitAnnotationCatalogCommit');
				if (typeof wait !== 'function')
					throw new Error('Main catalog commit observer was not installed.');
				const revision: unknown = await Reflect.apply(wait, globalThis, []);
				if (typeof revision !== 'number') throw new Error('Main catalog commit has no revision.');
				return revision;
			});
		},
	});
	if (catalogRevision === null) throw new Error('Main catalog commit has no revision.');
	return catalogRevision;
}

export function installAnnotationCatalogFailureObservation(): void {
	const OriginalMessageChannel = globalThis.MessageChannel;
	globalThis.MessageChannel = class AnnotationOwnerChannel extends OriginalMessageChannel {
		constructor() {
			super();
			// The production owner starts and retires port2; observation forwards nothing.
			this.port2.addEventListener('message', (event: MessageEvent<unknown>): void => {
				const message = event.data;
				if (typeof message !== 'object' || message === null) return;
				const kind: unknown = Reflect.get(message, 'kind');
				const state: unknown = Reflect.get(message, 'state');
				const view: unknown = Reflect.get(message, 'view');
				// Query failures publish unavailable after their automatic retry; a
				// retired subscription may still reopen and ends via viewRecoveryStatus.
				const finalProjectionFailure =
					kind === 'annotationProjectionConvergence' &&
					Reflect.get(message, 'surface') === 'review' &&
					typeof state === 'object' &&
					state !== null &&
					Reflect.get(state, 'kind') === 'unavailable' &&
					Reflect.get(state, 'catalogAuthorityRetired') === false;
				const finalViewFailure =
					kind === 'viewRecoveryStatus' &&
					typeof view === 'object' &&
					view !== null &&
					Reflect.get(view, 'kind') === 'review.annotations' &&
					Reflect.get(message, 'status') === 'failedRetryable';
				if (!finalProjectionFailure && !finalViewFailure) return;
				Reflect.set(
					window,
					'__bridgeAnnotationCatalogOwnerFailure',
					finalProjectionFailure
						? 'annotation-projection-unavailable'
						: 'annotation-view-recovery-failed',
				);
				window.dispatchEvent(new Event('__bridge_annotation_catalog_owner_changed'));
			});
		}
	};
}
