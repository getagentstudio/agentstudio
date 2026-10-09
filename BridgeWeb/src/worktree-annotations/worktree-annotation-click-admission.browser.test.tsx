import type { CodeView, CodeViewLineSelection } from '@pierre/diffs';
import { afterEach, describe, expect, onTestFailed, test, vi, type MockInstance } from 'vitest';
import { cleanup } from 'vitest-browser-react';

import {
	createClickAdmissionReviewHarness,
	captureClickAdmissionOriginals,
	type ClickAdmissionReviewHarness,
} from '../review-viewer/code-view/worktree-annotation-click-admission.browser.test-support.js';
import {
	completeCleanup,
	runWithOwnedCleanup,
} from './worktree-annotation-click-admission-cleanup.browser.test-support.js';
import { proveRetiredHoverIntent } from './worktree-annotation-click-admission-hover-retirement.browser.test-support.js';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import {
	dispatchPointer,
	requirePierreElement,
	clickCurrentUtility,
	pointerAt,
	pointerHitProbe,
	type PointerHitProbe,
} from './worktree-annotation-click-admission-pointer.browser.test-support.js';
import { proveDisposedInitialReadiness } from './worktree-annotation-click-admission-readiness.browser.test-support.js';
import {
	actEvent,
	observeTestFrameWait,
	proveHeldProductFrameIsolation,
} from './worktree-annotation-click-admission-render.browser.test-support.js';

const metadataPublicationOwner = vi.hoisted(() => ({
	publish: undefined as ((callback: () => void) => void) | undefined,
}));

vi.mock(
	import('../review-viewer/code-view/bridge-code-view-metadata-apply.js'),
	async (importOriginal) => {
		const metadataOwner = await importOriginal();
		function wrapCompletion(callback: () => void): () => void {
			return (): void => {
				if (metadataPublicationOwner.publish === undefined) callback();
				else metadataPublicationOwner.publish(callback);
			};
		}
		return {
			...metadataOwner,
			runBridgeCodeViewMetadataReconciliationInChunks: (props): void => {
				metadataOwner.runBridgeCodeViewMetadataReconciliationInChunks({
					...props,
					onComplete: wrapCompletion(props.onComplete),
				});
			},
			runBridgeCodeViewMetadataApplyInChunks: (props): void => {
				metadataOwner.runBridgeCodeViewMetadataApplyInChunks({
					...props,
					onComplete: wrapCompletion(props.onComplete),
				});
			},
		} satisfies typeof metadataOwner;
	},
);

const ownedHarnessDisposers = new Set<() => Promise<void>>();

function registerHarnessCleanup(dispose: () => Promise<void>): () => void {
	ownedHarnessDisposers.add(dispose);
	return (): void => {
		ownedHarnessDisposers.delete(dispose);
	};
}

async function renderReviewHarness(
	holdInteractionSetup = false,
	beforeRender?: () => void,
	afterSetupBeforeHover?: (codeView: CodeView) => void,
): Promise<ClickAdmissionReviewHarness> {
	return await createClickAdmissionReviewHarness({
		holdInteractionSetup,
		beforeRender,
		afterSetupBeforeHover,
		metadataPublicationOwner,
		registerFailureDiagnostic: (readSnapshot): void => {
			onTestFailed((context): void => {
				console.info(`GO17 pending-owner snapshot: ${context.task.name}`, readSnapshot());
			});
		},
		registerCleanup: registerHarnessCleanup,
	});
}

const composerSelector = '[aria-label="Write an annotation in Markdown"]';

describe('worktree annotation click admission through Pierre pointers', () => {
	afterEach(async (): Promise<void> => {
		await completeCleanup([...ownedHarnessDisposers, cleanup]);
	});

	test('disposes held initial readiness before later rows can resume its setup', async () => {
		await proveDisposedInitialReadiness({
			createHeld: (controls): Promise<ClickAdmissionReviewHarness> =>
				createClickAdmissionReviewHarness({
					metadataPublicationOwner,
					registerCleanup: controls.registerCleanup,
					registerFailureDiagnostic: (): void => {},
					isInitialReadinessReleased: controls.isReleased,
					recordInitialReadinessObserver: controls.recordObserver,
				}),
			registerCleanup: registerHarnessCleanup,
			admitLater: proveLaterHarnessAdmission,
		});
	});

	test('dispatches a context hover on the current row after setup-boundary replacement', async () => {
		let retiredRow: HTMLElement | undefined;
		const harness = await renderReviewHarness(false, undefined, (codeView): void => {
			const item = codeView.getItem('item-source');
			if (item === undefined) throw new Error('Expected the real Review item before replacement.');
			codeView.setItems([]);
			codeView.setItems([item]);
			codeView.render(true);
			expect(retiredRow?.isConnected).toBe(false);
		});
		let hoverSettlement: Promise<void> | undefined;
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				retiredRow = requirePierreElement(
					'[data-additions] [data-column-number="3"][data-line-type="context"]',
					'Expected the context row before replacement.',
				);
				const hover = harness.hoverAndClickUtility(retiredRow, 403);
				hoverSettlement = hover.catch((): void => {});
				const firstHoverAction = await Promise.race([
					harness.interactionSetup.hoverDispatched,
					hover.then((): never => {
						throw new Error('Hover completed without its owner fact.');
					}),
				]);
				expect(firstHoverAction).toBe('pointerMoveAfterSetup');
				await hover;
				await harness.waitForComposer(true);
				expect(harness.gutterAdmissions).toEqual([
					{ range: { start: 3, end: 3, side: 'additions' } },
				]);
				expect(document.querySelector(composerSelector)).not.toBeNull();
			},
			async (): Promise<void> => {
				await completeCleanup([
					harness.dispose,
					async (): Promise<void> => {
						await hoverSettlement;
					},
				]);
			},
		);
	});

	test('restores harness patches after setup rejects and a later harness admits', async () => {
		const originals = captureClickAdmissionOriginals(metadataPublicationOwner);
		const setupFailure = new Error('Controlled click-admission setup failure.');
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				await expect(
					renderReviewHarness(false, (): void => {
						throw setupFailure;
					}),
				).rejects.toBe(setupFailure);
				originals.assertRestored();
			},
			async (): Promise<void> => {
				// Contain the pre-fix red; the assertions above still require owner restoration.
				try {
					await cleanup();
				} finally {
					originals.restore();
				}
			},
		);
		await proveLaterHarnessAdmission();
	});

	test('preserves body and publication failures while restoring prototypes and frame spies', async () => {
		const originals = captureClickAdmissionOriginals(metadataPublicationOwner);
		const bodyFailure = new Error('Controlled click-admission body failure.');
		const publicationFailure = new Error('Controlled click-admission publication failure.');
		const harness = await renderReviewHarness();
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				let caughtFailure: unknown;
				try {
					await proveHeldProductFrameIsolation({
						prepareUtility: async (): Promise<void> => {},
						clickUtility: async (): Promise<void> => {
							throw bodyFailure;
						},
						waitForComposer: (): Promise<void> => harness.waitForComposer(true),
						dispose: async (): Promise<void> => {
							harness.publishForProof((): void => {
								throw publicationFailure;
							});
							await harness.dispose();
						},
					});
				} catch (error) {
					caughtFailure = error;
				}
				expect.soft(caughtFailure).toBeInstanceOf(AggregateError);
				if (caughtFailure instanceof AggregateError) {
					expect.soft(caughtFailure.errors).toContain(bodyFailure);
					expect.soft(caughtFailure.errors).toContain(publicationFailure);
				}
				originals.assertRestored();
			},
			async (): Promise<void> => {
				try {
					await cleanup();
				} finally {
					originals.restore();
				}
			},
		);
		await proveLaterHarnessAdmission();
	});

	test('owns preparation failure cleanup before installing the held-frame spies', async () => {
		const originals = captureClickAdmissionOriginals(metadataPublicationOwner);
		const preparationFailure = new Error('Controlled click-admission preparation failure.');
		const harness = await renderReviewHarness();
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				await expect(
					proveHeldProductFrameIsolation({
						prepareUtility: async (): Promise<void> => {
							throw preparationFailure;
						},
						clickUtility: async (): Promise<void> => {},
						waitForComposer: (): Promise<void> => harness.waitForComposer(true),
						dispose: (): Promise<void> => harness.dispose(),
					}),
				).rejects.toBe(preparationFailure);
				originals.assertRestored();
			},
			async (): Promise<void> => {
				try {
					await cleanup();
				} finally {
					originals.restore();
				}
			},
		);
		await proveLaterHarnessAdmission();
	});

	test('admits a right-side context-to-addition range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		await runWithOwnedCleanup(async (): Promise<void> => {
			// Selection reveal/programmatic scroll must not black out the next pointer gesture.
			await actEvent((): void => {
				harness.codeView.scrollTo({ type: 'position', position: 0, behavior: 'instant' });
			});
			const gesture = await dragRangeAndClickFirstUtility(
				'[data-additions] [data-column-number="1"][data-line-type="context"]',
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				101,
				harness.interactionLifecycle,
				(): CodeViewLineSelection | null => harness.codeView.getSelectedLines(),
			);

			expect(gesture.afterAnchorPublication).not.toContain('cleanup');
			expect(gesture.movePointerHit.lineNumber).toBe('2');
			expect(gesture.selectionAfterMove?.range).toEqual({
				end: 2,
				side: 'additions',
				start: 1,
			});
			expect(gesture.selectionAfterPointerUp?.range).toEqual({
				end: 2,
				side: 'additions',
				start: 1,
			});
			expect(gesture.utilityPointerDownHit.lineNumber).toBe('2');
			expect(gesture.utilityPointerUpHit.lineNumber).toBe('2');
			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 1 } },
			]);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		}, harness.dispose);
	});

	test('admits a left-side context-to-deletion range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		await runWithOwnedCleanup(async (): Promise<void> => {
			await dragRangeAndClickFirstUtility(
				'[data-deletions] [data-column-number="1"][data-line-type="context"]',
				'[data-deletions] [data-column-number="2"][data-line-type="change-deletion"]',
				201,
				harness.interactionLifecycle,
				(): CodeViewLineSelection | null => harness.codeView.getSelectedLines(),
			);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'deletions', start: 1 } },
			]);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		}, harness.dispose);
	});

	test('admits a backward right-side addition-to-context range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		await runWithOwnedCleanup(async (): Promise<void> => {
			await dragRangeAndClickFirstUtility(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'[data-additions] [data-column-number="1"][data-line-type="context"]',
				251,
				harness.interactionLifecycle,
				(): CodeViewLineSelection | null => harness.codeView.getSelectedLines(),
			);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 1 } },
			]);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		}, harness.dispose);
	});

	test('retirement after a live hover replays the original context intent on its replacement pre', async () => {
		await proveRetiredHoverIntent({
			metadataPublicationOwner,
			registerCleanup: registerHarnessCleanup,
		});
	});

	test('keeps repeated same-range and later new-range plus clicks admissible', async () => {
		const harness = await renderReviewHarness();
		await runWithOwnedCleanup(async (): Promise<void> => {
			const additionRow = requirePierreElement(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'Expected a right-side addition gutter row.',
			);
			await harness.hoverAndClickUtility(additionRow, 401);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();

			await clickCurrentUtility(402, harness.recordPendingWait);
			await harness.waitForComposer(true);
			expect(document.querySelectorAll(composerSelector)).toHaveLength(1);

			harness.recordPendingWait('Escape dispatch');
			await dismissComposer();
			await harness.waitForComposer(false);
			expect(document.querySelector(composerSelector)).toBeNull();

			const contextRow = requirePierreElement(
				'[data-additions] [data-column-number="3"][data-line-type="context"]',
				'Expected a later right-side context gutter row.',
			);
			await harness.hoverAndClickUtility(contextRow, 403);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 2 } },
				{ range: { end: 2, side: 'additions', start: 2 } },
				{ range: { end: 3, side: 'additions', start: 3 } },
			]);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		}, harness.dispose);
	});

	test('joins Escape dismissal without waiting for frame delivery', async () => {
		const harness = await renderReviewHarness();
		const heldFrames: FrameRequestCallback[] = [];
		let announceFrame: (() => void) | undefined;
		const frameRequested = new Promise<'frameRequested'>((resolve): void => {
			announceFrame = (): void => resolve('frameRequested');
		});
		let holdingTestFrame = false;
		const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
		let dismissal: Promise<void> | undefined;
		let frameSpy: MockInstance<typeof requestAnimationFrame> | undefined;
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				const row = requirePierreElement(
					'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
					'Expected an addition row before testing dismissal.',
				);
				await harness.hoverAndClickUtility(row, 601);
				await harness.waitForComposer(true);
				expect(document.querySelector(composerSelector)).not.toBeNull();
				frameSpy = vi
					.spyOn(globalThis, 'requestAnimationFrame')
					.mockImplementation((callback: FrameRequestCallback): number => {
						if (!holdingTestFrame) return requestFrame(callback);
						holdingTestFrame = false;
						heldFrames.push(callback);
						return heldFrames.length;
					});
				observeTestFrameWait((): void => {
					holdingTestFrame = true;
					announceFrame?.();
				});
				dismissal = dismissComposer();
				const outcome = await Promise.race([
					dismissal.then((): 'dismissed' => 'dismissed'),
					frameRequested,
				]);
				expect(outcome, 'Escape publication must complete without an unrelated frame.').toBe(
					'dismissed',
				);
				await harness.waitForComposer(false);
				expect(document.querySelector(composerSelector)).toBeNull();
			},
			async (): Promise<void> => {
				await completeCleanup([
					(): void => {
						frameSpy?.mockRestore();
					},
					(): void => observeTestFrameWait(undefined),
					(): void => {
						for (const callback of heldFrames.splice(0)) callback(0);
					},
					async (): Promise<void> => {
						await dismissal;
					},
					(): Promise<void> =>
						actEvent((): void => {
							for (const callback of heldFrames.splice(0)) callback(0);
						}),
					harness.dispose,
				]);
			},
		);
	});

	test('disposes its outcome wait with product frames held and leaves later acts admissible', async () => {
		const harness = await renderReviewHarness();
		await proveHeldProductFrameIsolation({
			prepareUtility: async (): Promise<void> => {
				const row = requirePierreElement(
					'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
					'Expected an addition row for the held product frame proof.',
				);
				await harness.waitForInteractionSetup(row);
				await actEvent((): void =>
					dispatchPointer(row, 'pointermove', pointerAt(row.getBoundingClientRect(), 701)),
				);
				await harness.waitForUtility();
			},
			clickUtility: async (): Promise<void> => {
				await clickCurrentUtility(702);
			},
			waitForComposer: (): Promise<void> => harness.waitForComposer(true),
			dispose: (): Promise<void> => harness.dispose(),
		});
	});

	test('awaits interaction setup before its first hover on already-rendered rows', async () => {
		const harness = await renderReviewHarness(true);
		const row = requirePierreElement(
			'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
			'Expected rendered rows while interaction setup is held.',
		);
		const hover = harness.hoverAndClickUtility(row, 501);
		const firstAction = await harness.interactionSetup.firstHoverAction;
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				expect(
					firstAction,
					'The hover must await its owner setup fact before dispatching a pointer.',
				).toBe('awaitingInteractionSetup');
				harness.interactionSetup.releaseSetup();
				await hover;
				expect(harness.gutterAdmissions).toEqual([
					{ range: { end: 2, side: 'additions', start: 2 } },
				]);
				await harness.waitForComposer(true);
				expect(document.querySelector(composerSelector)).not.toBeNull();
			},
			async (): Promise<void> => {
				await completeCleanup([
					(): void => harness.interactionSetup.releaseSetup(),
					async (): Promise<void> => {
						if (firstAction === 'pointerMoveBeforeSetup') {
							await actEvent((): void =>
								dispatchPointer(row, 'pointermove', pointerAt(row.getBoundingClientRect(), 501)),
							);
						}
					},
					(): Promise<void> => hover,
					harness.dispose,
				]);
			},
		);
	});
});

async function proveLaterHarnessAdmission(): Promise<void> {
	const laterHarness = await renderReviewHarness();
	await runWithOwnedCleanup(async (): Promise<void> => {
		const row = requirePierreElement(
			'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
			'Expected a later harness addition row.',
		);
		await laterHarness.hoverAndClickUtility(row, 801);
		await laterHarness.waitForComposer(true);
		expect(laterHarness.gutterAdmissions).toEqual([
			{ range: { start: 2, end: 2, side: 'additions' } },
		]);
		expect(document.querySelector(composerSelector)).not.toBeNull();
	}, laterHarness.dispose);
}

async function dragRangeAndClickFirstUtility(
	startSelector: string,
	endSelector: string,
	pointerId: number,
	interactionLifecycle: string[],
	getSelectedLines: () => CodeViewLineSelection | null,
): Promise<{
	readonly afterAnchorPublication: readonly string[];
	readonly selectionAfterMove: CodeViewLineSelection | null;
	readonly selectionAfterPointerUp: CodeViewLineSelection | null;
	readonly movePointerHit: PointerHitProbe;
	readonly utilityPointerDownHit: PointerHitProbe;
	readonly utilityPointerUpHit: PointerHitProbe;
}> {
	const startRow = requirePierreElement(startSelector, 'Expected the drag anchor gutter row.');
	const startBounds = startRow.getBoundingClientRect();
	const lifecycleCountBeforeAnchor = interactionLifecycle.length;
	await actEvent((): void => {
		dispatchPointer(startRow, 'pointerdown', pointerAt(startBounds, pointerId));
	});
	const afterAnchorPublication = interactionLifecycle.slice(lifecycleCountBeforeAnchor);
	const endRowAfterAnchorPublication = requirePierreElement(
		endSelector,
		'Expected the drag endpoint after anchor publication.',
	);
	const endBounds = endRowAfterAnchorPublication.getBoundingClientRect();
	const movePointerHit = pointerHitProbe(endRowAfterAnchorPublication, endBounds);
	await actEvent((): void => {
		dispatchPointer(endRowAfterAnchorPublication, 'pointermove', pointerAt(endBounds, pointerId));
	});
	const selectionAfterMove = getSelectedLines();
	const endRowAfterRangePublication = requirePierreElement(
		endSelector,
		'Expected the drag endpoint after range publication.',
	);
	const finalEndBounds = endRowAfterRangePublication.getBoundingClientRect();
	await actEvent((): void => {
		dispatchPointer(endRowAfterRangePublication, 'pointerup', pointerAt(finalEndBounds, pointerId));
	});
	const selectionAfterPointerUp = getSelectedLines();
	const utilityGesture = await clickCurrentUtility(pointerId + 1);
	return {
		afterAnchorPublication,
		movePointerHit,
		selectionAfterMove,
		selectionAfterPointerUp,
		...utilityGesture,
	};
}

async function dismissComposer(): Promise<void> {
	await actEvent((): void => {
		document.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }));
	});
}
