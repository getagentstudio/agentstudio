import {
	ClickAdmissionResourceOwner,
	type ClickAdmissionResourceGroup,
	type ClickAdmissionOwnedWait,
	type ClickAdmissionResourceToken,
} from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';

type FirstHoverAction =
	| 'awaitingInteractionSetup'
	| 'pointerMoveBeforeSetup'
	| 'pointerMoveAfterSetup';

/** The test observes completion of Pierre's existing setup owner, not rendered rows. */
export class PierreInteractionSetupFacts {
	readonly #readyPreNodes = new WeakSet<HTMLPreElement>();
	readonly #preByManager = new WeakMap<object, HTMLPreElement>();
	readonly #waiters = new Map<HTMLPreElement, Set<() => void>>();
	readonly #heldSetups: { readonly install: () => void; token?: ClickAdmissionResourceToken }[] =
		[];
	readonly #resources: ClickAdmissionResourceOwner;
	readonly #group: ClickAdmissionResourceGroup;
	readonly #firstHover: ClickAdmissionOwnedWait<FirstHoverAction>;
	readonly #hover: ClickAdmissionOwnedWait<FirstHoverAction>;
	readonly hoverDispatched: Promise<FirstHoverAction>;
	readonly #recordHoverDispatched: (action: FirstHoverAction) => void;
	readonly firstHoverAction: Promise<FirstHoverAction>;
	readonly #recordFirstHoverAction: (action: FirstHoverAction) => void;
	#holdingSetup: boolean;

	constructor(
		holdSetup: boolean,
		resources: ClickAdmissionResourceOwner,
		group: ClickAdmissionResourceGroup,
	) {
		this.#holdingSetup = holdSetup;
		this.#resources = resources;
		this.#group = group;
		this.#firstHover = resources.wait<FirstHoverAction>({ group, label: 'first hover action' });
		this.#hover = resources.wait<FirstHoverAction>({ group, label: 'hover dispatched' });
		this.firstHoverAction = this.#firstHover.promise;
		this.hoverDispatched = this.#hover.promise;
		this.#recordFirstHoverAction = this.#firstHover.resolve;
		this.#recordHoverDispatched = this.#hover.resolve;
		resources.register({
			group,
			kind: 'root',
			label: 'interaction setup facts',
			restore: (): void => this.dispose(),
		});
	}

	install(manager: object, pre: HTMLPreElement, setup: () => void): void {
		const install = (): void => {
			setup();
			this.#preByManager.set(manager, pre);
			this.#readyPreNodes.add(pre);
			for (const resolve of this.#waiters.get(pre) ?? []) resolve();
			this.#waiters.delete(pre);
		};
		if (this.#holdingSetup) {
			const held: { readonly install: () => void; token?: ClickAdmissionResourceToken } = {
				install,
			};
			held.token = this.#resources.register({
				group: this.#group,
				kind: 'wait',
				label: 'held interaction setup',
				restore: (): void => {
					const index = this.#heldSetups.indexOf(held);
					if (index >= 0) this.#heldSetups.splice(index, 1);
				},
			});
			this.#heldSetups.push(held);
		} else install();
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

	waitForSetup(row: HTMLElement): Promise<void> {
		this.#resources.assertOpen(this.#group);
		const pre = row.closest('pre');
		if (!(pre instanceof HTMLPreElement))
			return Promise.reject(new Error('Expected a Pierre row within its interaction pre.'));
		if (this.#readyPreNodes.has(pre)) return Promise.resolve();
		const completion = this.#resources.wait<void>({
			group: this.#group,
			label: 'interaction pre setup',
			error: new Error('Click-admission setup wait disposed.'),
		});
		const waiters = this.#waiters.get(pre) ?? new Set<() => void>();
		const finishSetup = (): void => completion.resolve(undefined);
		const removeWaiter = (): void => {
			waiters.delete(finishSetup);
			if (waiters.size === 0) this.#waiters.delete(pre);
			this.#resources.forget(indexResource);
		};
		const indexResource = this.#resources.register({
			group: this.#group,
			kind: 'wait',
			label: 'setup waiter index',
			restore: removeWaiter,
		});
		waiters.add(finishSetup);
		this.#waiters.set(pre, waiters);
		void completion.promise.then(removeWaiter, removeWaiter);
		this.#recordFirstHoverAction('awaitingInteractionSetup');
		return completion.promise;
	}

	releaseSetup(): void {
		this.#holdingSetup = false;
		for (const held of this.#heldSetups.splice(0)) {
			if (held.token !== undefined) this.#resources.forget(held.token);
			if (this.#resources.isOpen(this.#group)) held.install();
		}
	}

	dispose(): void {
		if (this.#heldSetups.length !== 0 || this.#waiters.size !== 0) {
			throw new Error('Click-admission test left interaction setup work unjoined.');
		}
	}
}
