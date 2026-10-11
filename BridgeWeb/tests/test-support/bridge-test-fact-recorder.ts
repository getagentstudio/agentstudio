type FactPredicate<TFact> = (fact: TFact) => boolean;

interface FactWaiter<TFact> {
	readonly inspect: (facts: readonly TFact[]) => boolean;
	readonly reject: (error: Error) => void;
	readonly label: string;
}

/** Append-only owner facts. Create before the stimulus; the runner owns the hang bound. */
export class BridgeTestFactRecorder<TFact> {
	readonly #facts: TFact[] = [];
	readonly #waiters = new Set<FactWaiter<TFact>>();
	#closedError: Error | null = null;

	record(fact: TFact): void {
		if (this.#closedError !== null) throw this.#closedError;
		this.#facts.push(fact);
		for (const waiter of this.#waiters) {
			if (waiter.inspect(this.#facts)) this.#waiters.delete(waiter);
		}
	}

	/** Occurrence counts owner facts, never attempts or scheduler turns. */
	waitFor(predicate: FactPredicate<TFact>, label: string, occurrence = 1): Promise<TFact> {
		if (!Number.isInteger(occurrence) || occurrence < 1)
			return Promise.reject(new Error(`Invalid fact occurrence for ${label}: ${occurrence}`));
		return this.#observe(label, (facts, resolve): boolean => {
			let matchCount = 0;
			for (const fact of facts) {
				if (predicate(fact) && ++matchCount === occurrence) {
					resolve(fact);
					return true;
				}
			}
			return false;
		});
	}

	/** Prove absence from attachment through the correlated closing fact, including that fact. */
	expectNone(
		predicate: FactPredicate<TFact>,
		closingFact: FactPredicate<TFact>,
		label = 'no forbidden fact before closing fact',
	): Promise<void> {
		return this.#observe(label, (facts, resolve, reject): boolean => {
			for (const fact of facts) {
				if (predicate(fact)) {
					reject(this.#failure(new Error('Forbidden fact observed before closing fact.'), label));
					return true;
				}
				if (closingFact(fact)) {
					resolve();
					return true;
				}
			}
			return false;
		});
	}

	close(error: Error): void {
		if (this.#closedError !== null) return;
		this.#closedError = error;
		for (const waiter of this.#waiters) {
			const failure = this.#failure(error, waiter.label);
			// Vitest's runner can report only its generic hang error. Retain the owner
			// label in raw output when teardown rejects a still-pending observation.
			console.info(failure.message);
			waiter.reject(failure);
		}
		this.#waiters.clear();
	}

	#observe<TResult>(
		label: string,
		inspect: (
			facts: readonly TFact[],
			resolve: (result: TResult) => void,
			reject: (error: Error) => void,
		) => boolean,
	): Promise<TResult> {
		return new Promise((resolve, reject): void => {
			const waiter = {
				label,
				reject,
				inspect: (facts: readonly TFact[]): boolean => inspect(facts, resolve, reject),
			} satisfies FactWaiter<TFact>;
			if (waiter.inspect(this.#facts)) return;
			if (this.#closedError !== null) {
				reject(this.#failure(this.#closedError, label));
				return;
			}
			this.#waiters.add(waiter);
		});
	}

	#failure(error: Error, label: string): Error {
		const recentFacts = this.#facts.slice(-10).map((fact): string => {
			try {
				return JSON.stringify(fact) ?? String(fact);
			} catch {
				return String(fact);
			}
		});
		return new Error(
			`Awaiting ${label}: ${error.message}; last recorded facts=[${recentFacts.join(', ')}]`,
			{
				cause: error,
			},
		);
	}
}
