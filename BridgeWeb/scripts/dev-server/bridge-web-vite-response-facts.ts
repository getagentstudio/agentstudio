import { z } from 'zod';

export const bridgeWebViteResponseFactPrefix = 'BRIDGE_WEB_VITE_RESPONSE_FACT ';
const responseCloseFactSchema = z.object({
	kind: z.literal('metadata-response-closed'),
	requestSequence: z.number().int().positive(),
	route: z.string().startsWith('/__bridge-product/stream'),
});
export type BridgeWebViteResponseCloseFact = z.infer<typeof responseCloseFactSchema>;

export interface BridgeWebViteResponseSubscription {
	readonly next: () => Promise<BridgeWebViteResponseCloseFact>;
	readonly close: () => void;
	readonly receivedCount: number;
}

// Subscribers register before their request. Only their live observation window
// is buffered; child pipe closure retires every subscription and pending read.
export class BridgeWebViteResponseFacts {
	readonly #subscriptions = new Set<BridgeWebViteResponseSubscription>();
	readonly #publishers = new Map<
		BridgeWebViteResponseSubscription,
		(fact: BridgeWebViteResponseCloseFact) => void
	>();
	#ended = false;
	#failure: Error | null = null;

	subscribe(name: string): BridgeWebViteResponseSubscription {
		const queued: BridgeWebViteResponseCloseFact[] = [];
		let closed = this.#ended;
		let receivedCount = 0;
		let pending: {
			resolve: (fact: BridgeWebViteResponseCloseFact) => void;
			reject: (reason: Error) => void;
		} | null = null;
		const endedError = (): Error =>
			new Error(`Vite response facts ended waiting=${name}`, { cause: this.#failure });
		const subscription: BridgeWebViteResponseSubscription = {
			get receivedCount(): number {
				return receivedCount;
			},
			next: (): Promise<BridgeWebViteResponseCloseFact> => {
				const promise = new Promise<BridgeWebViteResponseCloseFact>((resolve, reject): void => {
					if (closed) {
						reject(endedError());
						return;
					}
					const fact = queued.shift();
					if (fact !== undefined) {
						resolve(fact);
						return;
					}
					if (pending !== null) {
						reject(new Error(`Concurrent Vite fact read waiting=${name}`));
						return;
					}
					pending = { resolve, reject };
				});
				void promise.catch((): void => {});
				return promise;
			},
			close: (): void => {
				closed = true;
				queued.length = 0;
				pending?.reject(endedError());
				pending = null;
				this.#subscriptions.delete(subscription);
				this.#publishers.delete(subscription);
			},
		};
		if (!closed) {
			this.#subscriptions.add(subscription);
			this.#publishers.set(subscription, (fact): void => {
				receivedCount += 1;
				if (pending === null) queued.push(fact);
				else {
					pending.resolve(fact);
					pending = null;
				}
			});
		}
		return subscription;
	}

	acceptLine(line: string): void {
		if (this.#ended || !line.startsWith(bridgeWebViteResponseFactPrefix)) return;
		try {
			const fact = responseCloseFactSchema.parse(
				JSON.parse(line.slice(bridgeWebViteResponseFactPrefix.length)),
			);
			for (const publish of this.#publishers.values()) publish(fact);
		} catch (error: unknown) {
			this.#failure = new Error('Invalid Vite response-close fact', { cause: error });
			this.end();
		}
	}

	end(): void {
		this.#ended = true;
		for (const subscription of this.#subscriptions) subscription.close();
	}

	get failure(): Error | null {
		return this.#failure;
	}
	get subscriberCount(): number {
		return this.#subscriptions.size;
	}
}
