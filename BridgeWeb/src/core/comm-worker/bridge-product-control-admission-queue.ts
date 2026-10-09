/** Serial wire sequence owner. Escape controls run before waiting ordinary admissions. */
export class BridgeProductControlAdmissionQueue {
	readonly #ordinary: Array<() => Promise<void>> = [];
	readonly #escape: Array<() => Promise<void>> = [];
	#isRunning = false;
	#pendingCount = 0;

	get pendingCount(): number {
		return this.#pendingCount;
	}

	enqueue<TResult>(
		operation: () => Promise<TResult>,
		priority: 'ordinary' | 'escape' = 'ordinary',
	): Promise<TResult> {
		this.#pendingCount += 1;
		return new Promise<TResult>((resolve, reject): void => {
			const queued = async (): Promise<void> => {
				try {
					resolve(await operation());
				} catch (error) {
					reject(error);
				} finally {
					this.#pendingCount -= 1;
				}
			};
			if (priority === 'escape') this.#escape.push(queued);
			else this.#ordinary.push(queued);
			this.#drain();
		});
	}

	#drain(): void {
		if (this.#isRunning) return;
		const next = this.#escape.shift() ?? this.#ordinary.shift();
		if (next === undefined) return;
		this.#isRunning = true;
		void next().finally((): void => {
			this.#isRunning = false;
			this.#drain();
		});
	}
}
