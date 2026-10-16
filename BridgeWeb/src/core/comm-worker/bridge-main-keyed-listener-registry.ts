export class BridgeMainKeyedListenerRegistry<TKey> {
	readonly #listenersByKey = new Map<TKey, Set<() => void>>();

	subscribe(key: TKey, listener: () => void): () => void {
		const listeners = this.#listenersByKey.get(key) ?? new Set<() => void>();
		listeners.add(listener);
		this.#listenersByKey.set(key, listeners);
		return (): void => {
			listeners.delete(listener);
			if (listeners.size === 0) this.#listenersByKey.delete(key);
		};
	}

	publish(key: TKey): void {
		for (const listener of this.#listenersByKey.get(key) ?? []) listener();
	}

	clear(): void {
		this.#listenersByKey.clear();
	}
}
