export type ClickAdmissionResourceGroup = symbol;
export type ClickAdmissionResourceKind =
	| 'patch'
	| 'spy'
	| 'observer'
	| 'wait'
	| 'join'
	| 'root'
	| 'frame';
type RestoreResource = () => void | Promise<void>;

export interface ClickAdmissionResourceToken {
	readonly group: ClickAdmissionResourceGroup;
	readonly kind: ClickAdmissionResourceKind;
	readonly label: string;
	state: 'active' | 'closing' | 'closed';
	readonly restore: RestoreResource;
	completion?: Promise<void>;
}

export interface ClickAdmissionOwnedWait<TValue> {
	readonly promise: Promise<TValue>;
	readonly resolve: (value: TValue) => void;
	readonly reject: (error: unknown) => void;
}

/** One registry/controller per test. Groups select entries; they are not child owners. */
export class ClickAdmissionResourceOwner {
	readonly #controller = new AbortController();
	readonly #entries: ClickAdmissionResourceToken[] = [];
	readonly #groups = new Map<ClickAdmissionResourceGroup, Promise<void> | undefined>();
	#disposal: Promise<void> | undefined;
	#closing = false;

	get signal(): AbortSignal {
		return this.#controller.signal;
	}

	createGroup(label: string): ClickAdmissionResourceGroup {
		if (this.#closing) throw new Error('Click-admission outcome wait disposed.');
		const group = Symbol(label);
		this.#groups.set(group, undefined);
		return group;
	}

	isOpen(group: ClickAdmissionResourceGroup): boolean {
		return !this.#closing && this.#groups.has(group) && this.#groups.get(group) === undefined;
	}

	assertOpen(group: ClickAdmissionResourceGroup): void {
		if (!this.isOpen(group)) throw new Error('Click-admission outcome wait disposed.');
	}

	register(props: {
		readonly group: ClickAdmissionResourceGroup;
		readonly kind: ClickAdmissionResourceKind;
		readonly label: string;
		readonly restore: RestoreResource;
	}): ClickAdmissionResourceToken {
		this.assertOpen(props.group);
		const token: ClickAdmissionResourceToken = { ...props, state: 'active' };
		this.#entries.push(token);
		return token;
	}

	forget(token: ClickAdmissionResourceToken): void {
		token.state = 'closed';
	}

	release(token: ClickAdmissionResourceToken): Promise<void> {
		if (token.completion !== undefined) return token.completion;
		if (token.state === 'closed') return Promise.resolve();
		token.state = 'closing';
		token.completion = Promise.resolve().then(async (): Promise<void> => {
			try {
				await token.restore();
			} finally {
				token.state = 'closed';
			}
		});
		return token.completion;
	}

	async #restore(entries: readonly ClickAdmissionResourceToken[]): Promise<void> {
		const failures: unknown[] = [];
		for (const token of entries.toReversed()) {
			if (token.state === 'closed') continue;
			try {
				// oxlint-disable-next-line no-await-in-loop -- Restoration must finish in reverse installation order.
				await this.release(token);
			} catch (error) {
				if (!failures.includes(error)) failures.push(error);
			}
		}
		if (failures.length === 1) throw failures[0];
		if (failures.length > 1)
			throw new AggregateError(failures, 'Click-admission resource disposal failed.', {
				cause: failures[0],
			});
	}

	releaseGroup(group: ClickAdmissionResourceGroup): Promise<void> {
		const previous = this.#groups.get(group);
		if (previous !== undefined) return previous;
		const entries = this.#entries.filter((entry): boolean => entry.group === group);
		// Publish closing before running any user cleanup, including synchronous rejects.
		const completion = Promise.resolve().then((): Promise<void> => this.#restore(entries));
		this.#groups.set(group, completion);
		return completion;
	}

	dispose(): Promise<void> {
		if (this.#disposal !== undefined) return this.#disposal;
		this.#closing = true;
		this.#disposal = Promise.resolve().then((): Promise<void> => {
			this.#controller.abort();
			return this.#restore(this.#entries);
		});
		return this.#disposal;
	}

	patch<TTarget extends object, TKey extends keyof TTarget>(props: {
		readonly group: ClickAdmissionResourceGroup;
		readonly label: string;
		readonly target: TTarget;
		readonly key: TKey;
		readonly value: TTarget[TKey];
	}): ClickAdmissionResourceToken {
		const descriptor = Object.getOwnPropertyDescriptor(props.target, props.key);
		const token = this.register({
			group: props.group,
			kind: 'patch',
			label: props.label,
			restore: (): void => {
				if (descriptor === undefined) Reflect.deleteProperty(props.target, props.key);
				else Object.defineProperty(props.target, props.key, descriptor);
			},
		});
		props.target[props.key] = props.value;
		return token;
	}

	spy<TSpy extends { mockRestore(): void }>(props: {
		readonly group: ClickAdmissionResourceGroup;
		readonly label: string;
		readonly create: () => TSpy;
	}): { readonly spy: TSpy; readonly token: ClickAdmissionResourceToken } {
		const registration: { spy?: TSpy } = {};
		const token = this.register({
			group: props.group,
			kind: 'spy',
			label: props.label,
			restore: (): void => {
				registration.spy?.mockRestore();
			},
		});
		const spy = props.create();
		registration.spy = spy;
		return { spy, token };
	}

	wait<TValue>(props: {
		readonly group: ClickAdmissionResourceGroup;
		readonly label: string;
		readonly error?: Error;
	}): ClickAdmissionOwnedWait<TValue> {
		this.assertOpen(props.group);
		let resolvePromise: ((value: TValue) => void) | undefined;
		let rejectPromise: ((error: unknown) => void) | undefined;
		const promise = new Promise<TValue>((resolve, reject): void => {
			resolvePromise = resolve;
			rejectPromise = reject;
		});
		if (resolvePromise === undefined || rejectPromise === undefined)
			throw new Error('Expected owned wait registration.');
		const resolve = resolvePromise;
		const reject = rejectPromise;
		let settled = false;
		const finish = (): boolean => {
			if (settled) return false;
			settled = true;
			this.signal.removeEventListener('abort', abortWait);
			this.forget(token);
			return true;
		};
		const abortWait = (): void => {
			if (finish()) reject(props.error ?? new Error('Click-admission outcome wait disposed.'));
		};
		const token = this.register({
			group: props.group,
			kind: 'wait',
			label: props.label,
			restore: abortWait,
		});
		this.signal.addEventListener('abort', abortWait, { once: true });
		// A timeout may abandon the caller; cancellation remains observed without
		// changing the rejection delivered to that caller.
		void promise.catch((): void => {});
		return {
			promise,
			resolve: (value): void => {
				if (finish()) resolve(value);
			},
			reject: (error): void => {
				if (finish()) reject(error);
			},
		};
	}

	track<TValue>(props: {
		readonly group: ClickAdmissionResourceGroup;
		readonly label: string;
		readonly start: () => Promise<TValue>;
	}): Promise<TValue> {
		const registration: { operation?: Promise<TValue> } = {};
		const token = this.register({
			group: props.group,
			kind: 'join',
			label: props.label,
			restore: async (): Promise<void> => {
				await registration.operation?.catch((): void => {});
			},
		});
		const operation = props.start();
		registration.operation = operation;
		void operation.then(
			(): void => this.forget(token),
			(): void => this.forget(token),
		);
		return operation;
	}
}
