import type { BridgeViewerUnresolvedWaiter } from './product-only-real-router-contract.ts';

// Legacy Review metadata completion, kept per page generation: a document that
// received a legacy metadata response is complete once one of its own responses
// carries the final window. A response from another generation never completes,
// or creates, the awaited document's wait.
export class BridgeViewerLegacyMetadataCompletion {
	readonly #observedGenerations = new Set<number>();
	readonly #finalWindowGenerations = new Set<number>();
	// Pending waiters per generation; a generation's list is removed the moment its
	// final window arrives, so the failure diagnostic never lists a settled wait.
	readonly #waitersByGeneration = new Map<
		number,
		Set<{ readonly resolve: () => void; readonly reject: (error: Error) => void }>
	>();

	observeMetadataResponse(documentGeneration: number): void {
		this.#observedGenerations.add(documentGeneration);
	}

	observeFinalWindow(documentGeneration: number): void {
		this.#finalWindowGenerations.add(documentGeneration);
		for (const resolveWaiter of this.#waitersByGeneration.get(documentGeneration) ?? []) {
			resolveWaiter.resolve();
		}
		this.#waitersByGeneration.delete(documentGeneration);
	}

	// Waits, through `bound`, for `documentGeneration`'s final window when that
	// document received legacy metadata and has not yet completed. The waiter is
	// registered (and reported by `unresolvedWaiters`) before `bound` runs.
	async waitForGeneration(
		documentGeneration: number,
		bound: (completion: Promise<void>) => Promise<void>,
	): Promise<void> {
		if (
			!this.#observedGenerations.has(documentGeneration) ||
			this.#finalWindowGenerations.has(documentGeneration)
		) {
			return;
		}
		let resolveCompletion!: () => void;
		let rejectCompletion!: (error: Error) => void;
		const completion = new Promise<void>((resolve, reject): void => {
			resolveCompletion = resolve;
			rejectCompletion = reject;
		});
		void completion.catch((): void => {});
		const waiter = { resolve: resolveCompletion, reject: rejectCompletion };
		const waiters =
			this.#waitersByGeneration.get(documentGeneration) ??
			new Set<{ readonly resolve: () => void; readonly reject: (error: Error) => void }>();
		waiters.add(waiter);
		this.#waitersByGeneration.set(documentGeneration, waiters);
		try {
			await bound(completion);
		} finally {
			waiters.delete(waiter);
			if (waiters.size === 0 && this.#waitersByGeneration.get(documentGeneration) === waiters) {
				this.#waitersByGeneration.delete(documentGeneration);
			}
		}
	}

	close(reason: Error): void {
		for (const [generation, waiters] of this.#waitersByGeneration) {
			for (const waiter of waiters)
				waiter.reject(
					new Error(`${reason.message}: awaiting legacy-metadata-completion:g${generation}`, {
						cause: reason,
					}),
				);
		}
	}

	unresolvedWaiters(): readonly BridgeViewerUnresolvedWaiter[] {
		return [...this.#waitersByGeneration.keys()].map(
			(documentGeneration: number): BridgeViewerUnresolvedWaiter => ({
				documentGeneration,
				name: 'legacy-metadata-completion',
			}),
		);
	}
}
