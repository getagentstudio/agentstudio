/** Test-owner observations; buffered and future facts settle through the same matcher. */
export class BridgeProductTestFactRecorder<TFact> {
	readonly #facts: TFact[] = [];
	readonly #waiters = new Set<{
		readonly matches: (fact: TFact) => boolean;
		readonly count: number;
		readonly resolve: (fact: TFact) => void;
		readonly reject: (error: Error) => void;
	}>();
	#closedError: Error | null = null;

	record(fact: TFact): void {
		if (this.#closedError !== null) throw this.#closedError;
		this.#facts.push(fact);
		for (const waiter of this.#waiters) {
			const observed = this.#facts.filter(waiter.matches)[waiter.count - 1];
			if (observed === undefined) continue;
			this.#waiters.delete(waiter);
			waiter.resolve(observed);
		}
	}

	waitFor(matches: (fact: TFact) => boolean = (): boolean => true, count = 1): Promise<TFact> {
		const observed = this.#facts.filter(matches)[count - 1];
		if (observed !== undefined) return Promise.resolve(observed);
		if (this.#closedError !== null) return Promise.reject(this.#closedError);
		return new Promise((resolve, reject) => {
			this.#waiters.add({ matches, count, resolve, reject });
		});
	}

	close(error: Error): void {
		if (this.#closedError !== null) return;
		this.#closedError = error;
		for (const waiter of this.#waiters) waiter.reject(error);
		this.#waiters.clear();
	}
}
