import { act, createElement, useLayoutEffect, useState, type ReactElement } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Real Base UI transition proof uses the product motion CSS.
import '../src/app/bridge-app.css';
import {
	DropdownMenu,
	DropdownMenuCheckboxItem,
	DropdownMenuContent,
} from '../src/components/ui/dropdown-menu.js';
import { createBridgeProductDeferred } from '../src/core/comm-worker/bridge-product-async-queue.js';
import { BridgeProductTestFactRecorder } from '../src/core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import { actInteractAndSettleFileViewerCheckedMenuOption } from '../src/file-viewer/bridge-file-viewer-app-startup.browser.test-support.js';
import { BridgeTestFactRecorder } from './test-support/bridge-test-fact-recorder.js';
import {
	runBridgeTransitionFramesInAct,
	type BridgeTransitionFramePhase,
} from './test-support/bridge-transition-dom-fact.browser.test-support.js';
import { createHeldCheckboxTransitionFrame } from './test-support/held-checkbox-transition-frame.browser.test-support.js';

type AdapterOutcome<TResult> =
	| { readonly kind: 'completed'; readonly value: TResult }
	| { readonly kind: 'rejected'; readonly error: unknown };
function recordAdapterOutcome<TResult>(result: Promise<TResult>): Promise<AdapterOutcome<TResult>> {
	return result.then(
		(value) => ({ kind: 'completed', value }),
		(error) => ({ kind: 'rejected', error }),
	);
}

class HeldNativeFrame {
	disposition: 'held' | 'ran' | 'cancelled' = 'held';
	constructor(
		readonly nativeId: number,
		readonly callback: FrameRequestCallback,
	) {}
	run(): void {
		this.disposition = 'ran';
		this.callback(0);
	}
	// Deliberately replay a callback already cancelled by its owner. The adapter,
	// rather than this native stand-in, must reject that stale delivery.
	replayCancelledCallback(): void {
		this.callback(0);
	}
}

class HeldNativeFrameDriver {
	readonly #originalRequest = window.requestAnimationFrame;
	readonly #originalCancel = window.cancelAnimationFrame;
	readonly #registrations = new BridgeProductTestFactRecorder<HeldNativeFrame>();
	readonly #frames = new Map<number, HeldNativeFrame>();
	#nextNativeId = 0;
	readonly requestFrame: typeof window.requestAnimationFrame = (callback): number => {
		const frame = new HeldNativeFrame(++this.#nextNativeId, callback);
		this.#frames.set(frame.nativeId, frame);
		this.#registrations.record(frame);
		return frame.nativeId;
	};
	readonly cancelFrame: typeof window.cancelAnimationFrame = (nativeId): void => {
		const frame = this.#frames.get(nativeId);
		if (frame !== undefined) frame.disposition = 'cancelled';
	};
	constructor() {
		window.requestAnimationFrame = this.requestFrame;
		window.cancelAnimationFrame = this.cancelFrame;
	}
	get registeredCount(): number {
		return this.#nextNativeId;
	}

	nextFrameAfter(nativeId: number): Promise<HeldNativeFrame> {
		return this.#registrations.waitFor((frame) => frame.nativeId > nativeId);
	}
	expectRestoredAPIs(): void {
		expect(window.requestAnimationFrame).toBe(this.requestFrame);
		expect(window.cancelAnimationFrame).toBe(this.cancelFrame);
	}
	restore(): void {
		this.#registrations.close(new Error('Held native frame driver retired.'));
		window.requestAnimationFrame = this.#originalRequest;
		window.cancelAnimationFrame = this.#originalCancel;
	}
}

interface CounterPublication {
	readonly commits: BridgeProductTestFactRecorder<number>;
	setCount: ((count: number) => void) | undefined;
}
function OwnedFrameCounter(props: { readonly publication: CounterPublication }): ReactElement {
	const [count, setCount] = useState(0);
	props.publication.setCount = setCount;
	useLayoutEffect((): void => {
		props.publication.commits.record(count);
	}, [count, props.publication]);
	return createElement('output', null, String(count));
}

function phaseRecorder(): {
	readonly facts: BridgeProductTestFactRecorder<BridgeTransitionFramePhase>;
	readonly publish: (phase: BridgeTransitionFramePhase) => void;
} {
	const facts = new BridgeProductTestFactRecorder<BridgeTransitionFramePhase>();
	return { facts, publish: (phase) => facts.record(phase) };
}

describe('Bridge transition frame ownership and retirement', () => {
	test('keeps a held successor accepted during the final join act-owned after API restoration', async (context) => {
		const publication: CounterPublication = {
			commits: new BridgeProductTestFactRecorder<number>(),
			setCount: undefined,
		};
		await render(createElement(OwnedFrameCounter, { publication }));
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const phases = phaseRecorder();
		const outcome = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(
				async (): Promise<string> => {
					window.requestAnimationFrame((): void => {
						publication.setCount?.(1);
						window.requestAnimationFrame((): void => {
							publication.setCount?.(2);
						});
					});
					return 'operation closed';
				},
				{ onPhase: phases.publish },
			),
		);
		let successor: HeldNativeFrame | undefined;
		try {
			const barrier = await driver.nextFrameAfter(0);
			barrier.run();
			const predecessor = await driver.nextFrameAfter(barrier.nativeId);
			await phases.facts.waitFor((phase) => phase === 'final frame join');
			predecessor.run();
			successor = await driver.nextFrameAfter(predecessor.nativeId);
			expect(successor.disposition).toBe('held');
			expect(await outcome).toEqual({ kind: 'completed', value: 'operation closed' });
			driver.expectRestoredAPIs();
			// Replay is identical to every native delivery: no act in the driver/probe.
			successor.run();
			await publication.commits.waitFor((count) => count === 2);
			expect(document.querySelector('output')?.textContent).toBe('2');
		} finally {
			successor?.replayCancelledCallback();
			await outcome;
			driver.restore();
			phases.facts.close(new Error('Phase observation closed.'));
			publication.commits.close(new Error('Counter observation closed.'));
		}
	});

	test('retires a queued callback when the operation rejects and rejects stale replay', async (context) => {
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const writer = vi.fn();
		const failure = new Error('operation rejected at its owner');
		const outcome = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(async (): Promise<void> => {
				window.requestAnimationFrame(writer);
				throw failure;
			}),
		);
		try {
			const barrier = await driver.nextFrameAfter(0);
			barrier.run();
			const queued = await driver.nextFrameAfter(barrier.nativeId);
			expect(await outcome).toEqual({ kind: 'rejected', error: failure });
			driver.expectRestoredAPIs();
			expect(queued.disposition).toBe('cancelled');
			queued.replayCancelledCallback();
			expect(writer).not.toHaveBeenCalled();
		} finally {
			await outcome;
			driver.restore();
		}
	});

	test('owner abort retires the held registration barrier before entering the operation', async (context) => {
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const owner = new AbortController();
		const operation = vi.fn(async (): Promise<void> => {});
		const outcome = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(operation, { ownerAbortSignal: owner.signal }),
		);
		const barrier = await driver.nextFrameAfter(0);
		try {
			owner.abort();
			driver.expectRestoredAPIs();
			expect(barrier.disposition).toBe('cancelled');
			barrier.replayCancelledCallback();
			expect((await outcome).kind).toBe('rejected');
			expect(operation).not.toHaveBeenCalled();
		} finally {
			barrier.replayCancelledCallback();
			await outcome;
			driver.restore();
		}
	});

	test('owner abort retires a held final join and defines the callback disposition', async (context) => {
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const owner = new AbortController();
		const phases = phaseRecorder();
		const writer = vi.fn();
		const outcome = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(
				async (): Promise<void> => {
					window.requestAnimationFrame(writer);
				},
				{ ownerAbortSignal: owner.signal, onPhase: phases.publish },
			),
		);
		let queued: HeldNativeFrame | undefined;
		try {
			const barrier = await driver.nextFrameAfter(0);
			barrier.run();
			queued = await driver.nextFrameAfter(barrier.nativeId);
			await phases.facts.waitFor((phase) => phase === 'final frame join');
			owner.abort();
			driver.expectRestoredAPIs();
			expect(queued.disposition).toBe('cancelled');
			queued.replayCancelledCallback();
			expect((await outcome).kind).toBe('rejected');
			expect(writer).not.toHaveBeenCalled();
		} finally {
			queued?.replayCancelledCallback();
			await outcome;
			driver.restore();
			phases.facts.close(new Error('Phase observation closed.'));
		}
	});

	test('a retired predecessor never overwrites the newer adapter and is skipped at newer restoration', async (context) => {
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const olderOwner = new AbortController();
		const olderPhases = phaseRecorder();
		const older = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(
				async (): Promise<void> => {
					window.requestAnimationFrame((): void => {});
				},
				{
					ownerAbortSignal: olderOwner.signal,
					onPhase: olderPhases.publish,
				},
			),
		);
		const olderBarrier = await driver.nextFrameAfter(0);
		olderBarrier.run();
		const olderQueued = await driver.nextFrameAfter(olderBarrier.nativeId);
		await olderPhases.facts.waitFor((phase) => phase === 'final frame join');
		const newer = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(async (): Promise<void> => {}),
		);
		const newerBarrier = await driver.nextFrameAfter(olderQueued.nativeId);
		const newerRequest = window.requestAnimationFrame;
		const newerCancel = window.cancelAnimationFrame;
		try {
			olderOwner.abort();
			expect(window.requestAnimationFrame).toBe(newerRequest);
			expect(window.cancelAnimationFrame).toBe(newerCancel);
			expect(olderQueued.disposition).toBe('cancelled');
			expect(newerBarrier.disposition).toBe('held');
			expect((await older).kind).toBe('rejected');
			olderQueued.replayCancelledCallback();
			expect(window.requestAnimationFrame).toBe(newerRequest);
			newerBarrier.run();
			expect((await newer).kind).toBe('completed');
			driver.expectRestoredAPIs();
		} finally {
			olderQueued.replayCancelledCallback();
			newerBarrier.replayCancelledCallback();
			await Promise.all([older, newer]);
			driver.restore();
			olderPhases.facts.close(new Error('Older phase observation closed.'));
		}
	});

	test('owner abort retires a held successor after the helper has restored the APIs', async (context) => {
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const owner = new AbortController();
		const phases = phaseRecorder();
		const writer = vi.fn();
		const outcome = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(
				async (): Promise<void> => {
					window.requestAnimationFrame((): void => {
						window.requestAnimationFrame(writer);
					});
				},
				{ ownerAbortSignal: owner.signal, onPhase: phases.publish },
			),
		);
		try {
			const barrier = await driver.nextFrameAfter(0);
			barrier.run();
			const predecessor = await driver.nextFrameAfter(barrier.nativeId);
			await phases.facts.waitFor((phase) => phase === 'final frame join');
			predecessor.run();
			const successor = await driver.nextFrameAfter(predecessor.nativeId);
			expect((await outcome).kind).toBe('completed');
			driver.expectRestoredAPIs();
			expect(successor.disposition).toBe('held');
			owner.abort();
			expect(successor.disposition).toBe('cancelled');
			driver.expectRestoredAPIs();
			successor.replayCancelledCallback();
			expect(writer).not.toHaveBeenCalled();
		} finally {
			await outcome;
			driver.restore();
			phases.facts.close(new Error('Successor phase observation closed.'));
		}
	});

	test('abort at phase notification rejects before registering new native work', async (context) => {
		const driver = new HeldNativeFrameDriver();
		context.onTestFinished((): void => driver.restore());
		const owner = new AbortController();
		const operation = vi.fn(async (): Promise<void> => {});
		try {
			const outcome = await recordAdapterOutcome(
				runBridgeTransitionFramesInAct(operation, {
					ownerAbortSignal: owner.signal,
					onPhase: (): void => owner.abort(),
				}),
			);
			expect(outcome.kind).toBe('rejected');
			driver.expectRestoredAPIs();
			expect(driver.registeredCount).toBe(0);
			expect(operation).not.toHaveBeenCalled();
		} finally {
			driver.restore();
		}
	});

	test('afterEach retires an adapter still held at its registration barrier', async (context) => {
		const driver = new HeldNativeFrameDriver();
		const operation = vi.fn(async (): Promise<void> => {});
		const outcome = recordAdapterOutcome(runBridgeTransitionFramesInAct(operation));
		const barrier = await driver.nextFrameAfter(0);
		context.onTestFinished(async (): Promise<void> => {
			try {
				driver.expectRestoredAPIs();
				expect(barrier.disposition).toBe('cancelled');
				barrier.replayCancelledCallback();
				expect((await outcome).kind).toBe('rejected');
				expect(operation).not.toHaveBeenCalled();
			} finally {
				driver.restore();
			}
		});
	});
	test('afterEach retires an adapter still held at its final join', async (context) => {
		const driver = new HeldNativeFrameDriver();
		const phases = phaseRecorder();
		const writer = vi.fn();
		const outcome = recordAdapterOutcome(
			runBridgeTransitionFramesInAct(
				async (): Promise<void> => {
					window.requestAnimationFrame(writer);
				},
				{ onPhase: phases.publish },
			),
		);
		const barrier = await driver.nextFrameAfter(0);
		barrier.run();
		const queued = await driver.nextFrameAfter(barrier.nativeId);
		await phases.facts.waitFor((phase) => phase === 'final frame join');
		context.onTestFinished(async (): Promise<void> => {
			try {
				driver.expectRestoredAPIs();
				expect(queued.disposition).toBe('cancelled');
				queued.replayCancelledCallback();
				expect((await outcome).kind).toBe('rejected');
				expect(writer).not.toHaveBeenCalled();
			} finally {
				driver.restore();
				phases.facts.close(new Error('Cleanup phase observation closed.'));
			}
		});
	});
});

function CheckboxSelectionFixture(props: { readonly opened: () => void }): ReactElement {
	const [selection, setSelection] = useState<'old' | 'new'>('old');
	const item = (value: 'old' | 'new'): ReactElement =>
		createElement(
			DropdownMenuCheckboxItem,
			{
				key: value,
				checked: selection === value,
				onCheckedChange: (checked: boolean): void => {
					if (checked) setSelection(value);
				},
				closeOnClick: false,
				render: createElement('div', {
					'data-testid': 'worktree-file-filter-menu-option',
					'data-proof-option': value,
				}),
			},
			value,
		);
	return createElement(
		DropdownMenu,
		{
			defaultOpen: true,
			onOpenChangeComplete: (open: boolean): void => {
				if (open) props.opened();
			},
		},
		createElement(DropdownMenuContent, null, item('old'), item('new')),
	);
}

test('joins a real checkbox writer held at native delivery until the implementation boundary releases it', async (context) => {
	const opened = createBridgeProductDeferred<void>();
	await render(createElement(CheckboxSelectionFixture, { opened: (): void => opened.resolve() }));
	await act(async (): Promise<void> => {
		await opened.promise;
	});
	const option = document.querySelector<HTMLElement>('[data-proof-option="new"]');
	if (option === null) throw new Error('Expected the real new checkbox option.');
	const held = createHeldCheckboxTransitionFrame();
	context.onTestFinished((): void => held.close());
	const boundary = createBridgeProductDeferred<void>();
	const facts = new BridgeTestFactRecorder<'returned' | 'released'>();
	const opening = facts.mark();
	const outcome = recordAdapterOutcome(
		actInteractAndSettleFileViewerCheckedMenuOption({
			option,
			interaction: async (): Promise<void> => {
				held.arm();
				option.click();
			},
			onDiagnosticPhase: (phase: string): void => {
				// Observe the natural boundary supplied by either helper. This observer
				// neither wraps nor invokes its source callback.
				if (phase === 'before-indicator-completion' || phase === 'after-transition-frame-2')
					boundary.resolve();
			},
		}),
	).then((result) => {
		facts.record('returned');
		return result;
	});
	try {
		await boundary.promise;
		await held.arrived;
		expect(option.querySelector('[data-checked]')?.hasAttribute('data-starting-style')).toBe(true);
		const didNotFinishBeforeRelease = facts.expectNone(
			(fact) => fact === 'returned',
			(fact) => fact === 'released',
			{ from: opening, label: 'checkbox helper remains pending through held source release' },
		);
		facts.record('released');
		held.release();
		await didNotFinishBeforeRelease;
		expect((await outcome).kind).toBe('completed');
		expect(option.getAttribute('aria-checked')).toBe('true');
		expect(option.querySelector('[data-checked]')?.hasAttribute('data-starting-style')).toBe(false);
	} finally {
		held.close();
		await outcome;
		facts.close(new Error('Checkbox proof observation closed.'));
	}
});
