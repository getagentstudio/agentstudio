import type { Page, Response } from 'playwright';

import type { CommittedAnnotationOutcome } from './bridge-viewer-vite-annotation-wire-response-observation.ts';

// Test-only observation of the actual Main projection owner, never a replacement store.
export function observeAnnotationMainProjection(page: Page): {
	readonly install: () => Promise<void>;
} {
	let moduleUrl: string | null = null;
	const observeResponse = (response: Response): void => {
		if (new URL(response.url()).pathname.endsWith('/worktree-annotation-projection-store.ts')) {
			moduleUrl = response.url();
		}
	};
	page.on('response', observeResponse);
	return {
		install: async (): Promise<void> => {
			page.off('response', observeResponse);
			if (moduleUrl === null)
				throw new Error('Main annotation observer did not see the live store module.');
			// Native browser import avoids Vite SSR rewriting a serialized callback's imports.
			await page.evaluate(`(async () => {
				const { WorktreeAnnotationProjectionStore } = await import(${JSON.stringify(moduleUrl)});
				const observations = [];
				const stores = new Set();
				const storeObservers = new Set();
				const summarize = store => {
					const snapshot = store.getSnapshot();
					return {
						operationCorrelationId: snapshot.operationCorrelationId,
						revision: snapshot.revision, sourceGeneration: snapshot.sourceGeneration,
						presentationRevision: snapshot.presentationRevision, readStatus: snapshot.readStatus,
						application: snapshot.reviewAnnotationApplication === null ? null : {
							applicationId: snapshot.reviewAnnotationApplication.applicationId,
							affectedItemCount: snapshot.reviewAnnotationApplication.affectedItemIds?.length ?? null,
							changedThreadCount: snapshot.reviewAnnotationApplication.changedThreadOwnerContexts.length
						},
						sessions: snapshot.sessions.slice(0, 8).map(session => ({
							sessionId: session.sessionId, lifecycle: session.lifecycle,
							sourceRelationship: session.sourceRelationship, semanticRevision: session.semanticRevision
						})),
						threads: [...snapshot.threads, ...snapshot.commandConfirmedThreads].slice(0, 8).map(thread => ({
							threadId: thread.context.threadId, placement: thread.context.placement,
							sourceRole: thread.context.sourceRole, startLine: thread.context.startLine,
							endLine: thread.context.endLine, messageCount: thread.messages.length,
							sessionIds: [...new Set(thread.messages.map(message => message.sessionId))]
						}))
					};
				};
				for (const method of ['apply', 'applyCatalogStaging', 'recordCommandOutcome', 'prepareForWorkerReplacement', 'markRefreshing', 'markUnavailable']) {
					const original = WorktreeAnnotationProjectionStore.prototype[method];
					WorktreeAnnotationProjectionStore.prototype[method] = function (...args) {
						const result = original.apply(this, args);
						if (!stores.has(this)) {
							stores.add(this);
							for (const observeStore of storeObservers) observeStore(this);
						}
						observations.push({ method, result: typeof result === 'boolean' ? result : result?.status ?? null,
							atMilliseconds: Math.round(performance.now()), snapshot: summarize(this) });
						if (observations.length > 24) observations.shift();
						return result;
					};
				}
				// Subscribe to the owning store, including its current snapshot. A retired
				// HTTP descriptor is not the installation fact for a saved message.
				Object.defineProperty(globalThis, '__bridgeAnnotationMainProjectionAwaitReceipt', {
					value: receipt => new Promise(resolve => {
						const subscriptions = new Map();
						let completed = false;
						const inspect = store => {
							if (completed) return;
							const snapshot = store.getSnapshot();
							if (snapshot.readStatus.kind !== 'ready' ||
								snapshot.unreconciledCommandReceiptSessionIds.includes(receipt.sessionId)) return;
							const session = snapshot.sessions.find(candidate => candidate.sessionId === receipt.sessionId);
							if (session === undefined || session.semanticRevision < receipt.sessionRevision) return;
							const projected = snapshot.threads.flatMap(thread => thread.messages).find(message =>
								message.sessionId === receipt.sessionId && message.messageId === receipt.messageId);
							if (projected === undefined || projected.messageRevision < receipt.messageRevision ||
								projected.savedRevision === null || projected.draft !== null ||
								projected.sessionRevision < receipt.sessionRevision || projected.threadRevision < receipt.threadRevision) return;
							completed = true;
							storeObservers.delete(observeStore);
							for (const unsubscribe of subscriptions.values()) unsubscribe();
							resolve();
						};
						const observeStore = store => {
							if (completed || subscriptions.has(store)) return;
							subscriptions.set(store, store.subscribe(() => inspect(store)));
							inspect(store);
						};
						storeObservers.add(observeStore);
						for (const store of stores) observeStore(store);
					})
				});
				Object.defineProperty(globalThis, '__bridgeAnnotationMainProjectionObservation', {
					get: () => ({ observations, current: [...stores].map(summarize) })
				});
			})()`);
		},
	};
}

export async function readAnnotationMainProjectionObservation(page: Page): Promise<unknown> {
	return await page.evaluate((): unknown =>
		Reflect.get(globalThis, '__bridgeAnnotationMainProjectionObservation'),
	);
}

export async function waitForAnnotationMainProjectionReceipt(props: {
	readonly page: Page;
	readonly receipt: CommittedAnnotationOutcome;
}): Promise<void> {
	await props.page.evaluate(async (receipt): Promise<void> => {
		const waitForReceipt: unknown = Reflect.get(
			globalThis,
			'__bridgeAnnotationMainProjectionAwaitReceipt',
		);
		if (typeof waitForReceipt !== 'function') {
			throw new Error('Main annotation projection receipt observer was not installed.');
		}
		await Reflect.apply(waitForReceipt, globalThis, [receipt]);
	}, props.receipt);
}
