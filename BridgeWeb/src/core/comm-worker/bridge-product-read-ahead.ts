/** Keep a fetch body pull outstanding while the current chunk is decoded and routed. */
export class BridgeProductReadAhead {
	readonly #reader: ReadableStreamDefaultReader<Uint8Array>;
	#pending: Promise<ReadableStreamReadResult<Uint8Array>>;

	constructor(reader: ReadableStreamDefaultReader<Uint8Array>) {
		this.#reader = reader;
		this.#pending = reader.read();
		void this.#pending.catch((): void => {});
	}

	async next(): Promise<ReadableStreamReadResult<Uint8Array>> {
		const result = await this.#pending;
		if (!result.done) {
			this.#pending = this.#reader.read();
			void this.#pending.catch((): void => {});
		}
		return result;
	}
}
