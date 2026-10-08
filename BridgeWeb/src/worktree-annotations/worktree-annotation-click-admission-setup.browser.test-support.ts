type FirstHoverAction =
	| 'awaitingInteractionSetup'
	| 'pointerMoveBeforeSetup'
	| 'pointerMoveAfterSetup';

/** The test observes completion of Pierre's existing setup owner, not rendered rows. */
export class PierreInteractionSetupFacts {
	readonly #readyPreNodes = new WeakSet<HTMLPreElement>();
	readonly #preByManager = new WeakMap<object, HTMLPreElement>();
	readonly #waiters = new Map<HTMLPreElement, Set<() => void>>();
	readonly #heldSetups: (() => void)[] = [];
	readonly hoverDispatched: Promise<FirstHoverAction>;
	readonly #recordHoverDispatched: (action: FirstHoverAction) => void;
	readonly firstHoverAction: Promise<FirstHoverAction>;
	readonly #recordFirstHoverAction: (action: FirstHoverAction) => void;
	#holdingSetup: boolean;

	constructor(holdSetup: boolean) {
		this.#holdingSetup = holdSetup;
		const registration: {
			resolve?: (action: FirstHoverAction) => void;
			resolveHover?: (action: FirstHoverAction) => void;
		} = {};
		this.firstHoverAction = new Promise<FirstHoverAction>((resolve): void => {
			registration.resolve = resolve;
		});
		this.hoverDispatched = new Promise<FirstHoverAction>((resolve): void => {
			registration.resolveHover = resolve;
		});
		if (registration.resolve === undefined || registration.resolveHover === undefined) {
			throw new Error('Expected the first-hover fact continuation to be registered.');
		}
		this.#recordFirstHoverAction = registration.resolve;
		this.#recordHoverDispatched = registration.resolveHover;
	}

	install(manager: object, pre: HTMLPreElement, setup: () => void): void {
		const install = (): void => {
			setup();
			this.#preByManager.set(manager, pre);
			this.#readyPreNodes.add(pre);
			for (const resolve of this.#waiters.get(pre) ?? []) resolve();
			this.#waiters.delete(pre);
		};
		if (this.#holdingSetup) this.#heldSetups.push(install);
		else install();
	}

	retire(manager: object): void {
		const pre = this.#preByManager.get(manager);
		if (pre !== undefined) this.#readyPreNodes.delete(pre);
		this.#preByManager.delete(manager);
	}

	recordCompletedHover(row: HTMLElement): void {
		const action = this.isReady(row) ? 'pointerMoveAfterSetup' : 'pointerMoveBeforeSetup';
		this.#recordFirstHoverAction(action);
		this.#recordHoverDispatched(action);
	}

	isReady(row: HTMLElement): boolean {
		const pre = row.closest('pre');
		return pre instanceof HTMLPreElement && this.#readyPreNodes.has(pre);
	}

	waitForSetup(row: HTMLElement, signal?: AbortSignal): Promise<void> {
		if (signal?.aborted === true)
			return Promise.reject(new Error('Click-admission setup wait disposed.'));
		const pre = row.closest('pre');
		if (!(pre instanceof HTMLPreElement)) {
			return Promise.reject(new Error('Expected a Pierre row within its interaction pre.'));
		}
		if (this.#readyPreNodes.has(pre)) return Promise.resolve();
		return new Promise<void>((resolve, reject): void => {
			const waiters = this.#waiters.get(pre) ?? new Set<() => void>();
			const finishSetup = (): void => {
				signal?.removeEventListener('abort', abortSetup);
				resolve();
			};
			const abortSetup = (): void => {
				waiters.delete(finishSetup);
				if (waiters.size === 0) this.#waiters.delete(pre);
				reject(new Error('Click-admission setup wait disposed.'));
			};
			signal?.addEventListener('abort', abortSetup, { once: true });
			waiters.add(finishSetup);
			this.#waiters.set(pre, waiters);
			this.#recordFirstHoverAction('awaitingInteractionSetup');
		});
	}

	releaseSetup(): void {
		this.#holdingSetup = false;
		for (const setup of this.#heldSetups.splice(0)) setup();
	}

	dispose(): void {
		if (this.#heldSetups.length !== 0 || this.#waiters.size !== 0) {
			throw new Error('Click-admission test left interaction setup work unjoined.');
		}
	}
}
