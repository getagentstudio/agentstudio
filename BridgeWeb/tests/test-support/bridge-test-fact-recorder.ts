type FactPredicate<TFact> = (fact: TFact) => boolean;

interface NegativeFactExpectationOptions {
	readonly from: number;
	readonly label: string;
}

interface FactWaiter<TFact> {
	readonly inspect: (facts: readonly TFact[]) => boolean;
	readonly reject: (error: Error) => void;
	readonly label: string;
}

/** Append-only owner facts. Create before the stimulus; the runner owns the hang bound. */
export class BridgeTestFactRecorder<TFact> {
	readonly #facts: TFact[] = [];
	readonly #waiters = new Set<FactWaiter<TFact>>();
	#closedSource: { readonly error: Error; readonly factCount: number } | null = null;

	record(fact: TFact): void {
		this.#facts.push(fact);
		// Late source emissions remain diagnostic evidence; they cannot reopen observations.
		if (this.#closedSource !== null) return;
		for (const waiter of this.#waiters) {
			if (waiter.inspect(this.#facts)) this.#waiters.delete(waiter);
		}
	}

	/** Matches recorded or future facts; correlate the predicate to its operation. Occurrence counts matching facts. */
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

	/** Mark before the stimulus; negatives observe only facts at or after this opening position. */
	mark(): number {
		return this.#facts.length;
	}

	/** Prove absence from the opening position through the correlated close, inclusive; label names that close. */
	expectNone(
		predicate: FactPredicate<TFact>,
		closingFact: FactPredicate<TFact>,
		options: NegativeFactExpectationOptions,
	): Promise<void> {
		return this.#observe(options.label, (facts, resolve, reject): boolean => {
			for (const fact of facts.slice(options.from)) {
				if (predicate(fact)) {
					reject(
						this.#failure(
							new Error(
								`Forbidden fact ${this.#describeFact(fact)} observed before closing fact (${options.label}).`,
							),
							options.label,
						),
					);
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
		if (this.#closedSource !== null) return;
		this.#closedSource = { error, factCount: this.#facts.length };
		const pendingWaiters = [...this.#waiters];
		this.#waiters.clear();
		for (const waiter of pendingWaiters) {
			const failure = this.#failure(error, waiter.label);
			// Vitest's runner can report only its generic hang error. Retain the owner
			// label in raw output when teardown rejects a still-pending observation.
			console.info(failure.message);
			waiter.reject(failure);
		}
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
			const observableFacts =
				this.#closedSource === null
					? this.#facts
					: this.#facts.slice(0, this.#closedSource.factCount);
			if (waiter.inspect(observableFacts)) return;
			if (this.#closedSource !== null) {
				reject(this.#failure(this.#closedSource.error, label));
				return;
			}
			this.#waiters.add(waiter);
		});
	}

	#failure(error: Error, label: string): Error {
		const recentFacts = this.#facts.slice(-10).map((fact): string => this.#describeFact(fact));
		return new Error(
			`Awaiting ${label}: ${error.message}; last recorded facts=[${recentFacts.join(', ')}]`,
			{
				cause: error,
			},
		);
	}

	#describeFact(fact: TFact): string {
		let description: string;
		try {
			description = JSON.stringify(fact) ?? String(fact);
		} catch {
			try {
				description = String(fact);
			} catch {
				description = '<unformattable fact>';
			}
		}
		return description.length > 400 ? `${description.slice(0, 397)}...` : description;
	}
}
