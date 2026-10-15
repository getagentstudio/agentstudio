import { uuidv7 } from 'uuidv7';

import { handleLaunchPromise, type HandledLaunchPromise } from './handled-launch-promise.ts';

/** Diagnostic state only: the launch still owns every resource and retirement join. */
export class BridgeWebLaunchStepDiagnostics {
	readonly #launchId = uuidv7();
	readonly #pendingSteps = new Map<symbol, string>();
	readonly #nativeBrowserExists: () => boolean;

	constructor(nativeBrowserExists: () => boolean) {
		this.#nativeBrowserExists = nativeBrowserExists;
	}

	observe<TValue>(
		name: string,
		promise: Promise<TValue>,
		retirement: boolean,
	): HandledLaunchPromise<TValue> {
		const observation = handleLaunchPromise(promise, name);
		const identity = Symbol(name);
		this.#pendingSteps.set(identity, name);
		if (retirement) this.#writeRetirement(name, 'started');
		void observation.settled.then((outcome): void => {
			if (retirement) this.#writeRetirement(name, outcome.kind);
			this.#pendingSteps.delete(identity);
		});
		return observation;
	}

	get pendingSteps(): readonly string[] {
		return [...this.#pendingSteps.values()];
	}

	get pendingDiagnostics(): readonly string[] {
		return [...this.#pendingSteps.values()].map((name): string => this.#describeStep(name));
	}

	#describeStep(name: string): string {
		return `launch=${this.#launchId} nativeBrowser=${this.#nativeBrowserExists()} operation=${JSON.stringify(name)}`;
	}

	#writeRetirement(name: string, outcome: 'started' | 'succeeded' | 'failed'): void {
		const phase = outcome === 'started' ? 'start' : 'settle';
		process.stderr.write(
			`BRIDGE_LAUNCH_RETIREMENT waiting=${name}; timestamp=${new Date().toISOString()} ${this.#describeStep(name)} phase=${phase} outcome=${outcome}\n`,
		);
	}
}
