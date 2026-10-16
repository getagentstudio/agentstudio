import {
	bridgeProductSurfaceSchema,
	type BridgeProductSurface,
} from './bridge-product-contract-primitives.js';

/**
 * Owns each surface's worker derivation epoch and the admission gate that orders
 * requests after an advance. Native refuses a control tagged below its surface
 * floor, so every request admitted at a new epoch must follow the releases of the
 * subscriptions that advance retired.
 */
export class BridgeProductSurfaceEpochAuthority {
	readonly #epochs = new Map<BridgeProductSurface, number>();
	readonly #advanceBySurface = new Map<BridgeProductSurface, Promise<void>>();

	constructor(initialEpochs: Readonly<Partial<Record<BridgeProductSurface, number>>> = {}) {
		for (const [rawSurface, epoch] of Object.entries(initialEpochs)) {
			const surface = bridgeProductSurfaceSchema.parse(rawSurface);
			assertBridgeProductEpoch(epoch);
			this.#epochs.set(surface, epoch);
		}
	}

	current(surface: BridgeProductSurface): number {
		return this.#epochs.get(surface) ?? 0;
	}

	/**
	 * Advances the surface at once and holds its admissions until `releaseOlder`'s
	 * releases settle (and any earlier advance on the surface has).
	 */
	advance(
		surface: BridgeProductSurface,
		releaseOlder: (nextEpoch: number) => readonly Promise<void>[],
	): number {
		const nextEpoch = this.current(surface) + 1;
		assertBridgeProductEpoch(nextEpoch);
		const releases = releaseOlder(nextEpoch);
		this.#epochs.set(surface, nextEpoch);
		const previousAdvance = this.#advanceBySurface.get(surface) ?? Promise.resolve();
		const advance = previousAdvance
			.then(async (): Promise<void> => {
				await Promise.allSettled(releases);
			})
			.finally((): void => {
				if (this.#advanceBySurface.get(surface) === advance) {
					this.#advanceBySurface.delete(surface);
				}
			});
		this.#advanceBySurface.set(surface, advance);
		return nextEpoch;
	}

	/**
	 * Waits out any advance on the surface, then runs `admit` with the surface epoch
	 * in the same synchronous turn as the final check. An advance can then never
	 * begin between the check and the request `admit` queues.
	 */
	async admitAt<TAdmission>(
		surface: BridgeProductSurface,
		admit: (workerDerivationEpoch: number) => TAdmission,
	): Promise<TAdmission> {
		for (
			let advance = this.#advanceBySurface.get(surface);
			advance !== undefined;
			advance = this.#advanceBySurface.get(surface)
		) {
			// eslint-disable-next-line no-await-in-loop -- A newer advance may begin while one settles.
			await advance;
		}
		return admit(this.current(surface));
	}
}

function assertBridgeProductEpoch(epoch: number): void {
	if (!Number.isSafeInteger(epoch) || epoch < 0) {
		throw new Error('Bridge product derivation epochs must be nonnegative safe integers.');
	}
}
