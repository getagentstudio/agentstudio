import type { Page } from 'playwright';
import { describe, expect, test, vi } from 'vitest';

import type { BridgeCompleteJourneyPhaseCompletions } from './complete-journey-cohort.ts';
import {
	bridgeCompleteJourneyFailedAttempt,
	collectBridgeDevelopmentCompleteJourneyLaunch,
} from './complete-journey-collector.ts';
import {
	bridgeCompleteJourneyActivationSequenceAfter,
	bridgeCompleteJourneyTelemetryWitnessesSatisfied,
} from './complete-journey-telemetry.ts';
import type { WorktreeBridgeTelemetrySampleProof } from './types.ts';
import { createOwnedVerifierJourneyDeadline } from './verifier-journey-deadline.ts';

describe('Bridge complete journey telemetry correlation', () => {
	test('fails a held attempt by its pending step and stops before another page acquisition', async () => {
		const pageClose = vi.fn(async (): Promise<void> => {});
		const page = { close: pageClose } as unknown as Page;
		const pendingSteps = new Set<string>();
		const deadlineControl: { expiry: (() => void) | null } = { expiry: null };
		const deadline = createOwnedVerifierJourneyDeadline(
			{
				closePages: async (): Promise<void> => page.close(),
				pendingSteps: (): readonly string[] => [...pendingSteps],
			},
			{
				schedule: (expire): (() => void) => {
					deadlineControl.expiry = expire;
					return (): void => {
						if (deadlineControl.expiry === expire) deadlineControl.expiry = null;
					};
				},
			},
		);
		let pageAcquisitionCount = 0;
		let resolvePageAcquired: (() => void) | undefined;
		const pageAcquired = new Promise<void>((resolve): void => {
			resolvePageAcquired = resolve;
		});
		let resolveJourney: (() => void) | undefined;
		const heldJourney = new Promise<void>((resolve): void => {
			resolveJourney = resolve;
		});
		let resolveJourneyStarted: (() => void) | undefined;
		const journeyStarted = new Promise<void>((resolve): void => {
			resolveJourneyStarted = resolve;
		});
		vi.stubGlobal(
			'fetch',
			vi.fn(
				async (): Promise<Response> =>
					new Response(
						JSON.stringify({
							acceptedSampleCount: 0,
							failedBatchCount: 0,
							marker: 'test',
							serviceVersion: 'test',
							worktreeHash: 'test',
						}),
					),
			),
		);
		try {
			const collection = collectBridgeDevelopmentCompleteJourneyLaunch(
				{ attemptCount: 2, launchId: 'launch', sourceHead: 'HEAD' },
				{
					collectJourney: async (): Promise<BridgeCompleteJourneyPhaseCompletions> => {
						resolveJourneyStarted?.();
						await heldJourney;
						return {};
					},
					makePage: async (): Promise<Page> => {
						pageAcquisitionCount += 1;
						resolvePageAcquired?.();
						return page;
					},
					ownerSignal: deadline.signal,
					pendingSteps,
					renewLaunchHangBound: deadline.renew,
				},
			);
			await pageAcquired;
			await journeyStarted;
			const expiry = deadlineControl.expiry;
			if (typeof expiry !== 'function')
				throw new Error('Expected the launch deadline to be armed.');
			expiry();
			await expect(collection).rejects.toThrow(
				'BRIDGE_VERIFIER_JOURNEY_DEADLINE_EXCEEDED waiting=firstFile journey',
			);
			expect(pageAcquisitionCount).toBe(1);
			expect(pageClose).toHaveBeenCalled();
			resolveJourney?.();
			await deadline.dispose();
		} finally {
			vi.unstubAllGlobals();
		}
	});

	test('allows a cohort longer than one bound when every attempt finishes before its own bound', async () => {
		const page = { close: vi.fn(async (): Promise<void> => {}) } as unknown as Page;
		const pendingSteps = new Set<string>();
		let activeExpiry: (() => void) | null = null;
		const deadline = createOwnedVerifierJourneyDeadline(
			{
				closePages: async (): Promise<void> => page.close(),
				pendingSteps: (): readonly string[] => [...pendingSteps],
			},
			{
				schedule: (expire): (() => void) => {
					activeExpiry = expire;
					return (): void => {
						if (activeExpiry === expire) activeExpiry = null;
					};
				},
			},
		);
		let pageAcquisitionCount = 0;
		let launchBoundRenewals = 0;
		vi.stubGlobal(
			'fetch',
			vi.fn(
				async (): Promise<Response> =>
					new Response(
						JSON.stringify({
							acceptedSampleCount: 0,
							failedBatchCount: 0,
							marker: 'test',
							serviceVersion: 'test',
							worktreeHash: 'test',
						}),
					),
			),
		);
		try {
			const launch = await collectBridgeDevelopmentCompleteJourneyLaunch(
				{ attemptCount: 2, launchId: 'launch', sourceHead: 'HEAD' },
				{
					collectJourney: async (): Promise<BridgeCompleteJourneyPhaseCompletions> => ({
						commitPaint: 1,
					}),
					makePage: async (): Promise<Page> => {
						pageAcquisitionCount += 1;
						return page;
					},
					ownerSignal: deadline.signal,
					pendingSteps,
					renewLaunchHangBound: (): void => {
						launchBoundRenewals += 1;
						deadline.renew();
					},
				},
			);
			expect(launch.attemptsByJourney.firstFile).toHaveLength(2);
			expect(
				launch.attemptsByJourney.firstFile.every((attempt) => attempt.outcome === 'succeeded'),
			).toBe(true);
			expect(pageAcquisitionCount).toBe(8);
			expect(launchBoundRenewals).toBe(8);
			expect(activeExpiry).not.toBeNull();
			expect(deadline.signal.aborted).toBe(false);
			await deadline.dispose();
		} finally {
			vi.unstubAllGlobals();
		}
	});

	test('preserves completed phases when a later journey phase fails', () => {
		const attempt = bridgeCompleteJourneyFailedAttempt({
			attemptId: 'development-launch-1-firstReview-4',
			durationMilliseconds: 975,
			failureReason: 'review_usable_paint_failed',
			phaseCompletionElapsedMilliseconds: {
				handshakeWorker: 250,
				pageApplication: 120,
				selectionContent: 700,
				sourceMetadata: 520,
			},
		});

		expect(attempt).toEqual({
			attemptId: 'development-launch-1-firstReview-4',
			durationMilliseconds: 975,
			failureReason: 'review_usable_paint_failed',
			outcome: 'failed',
			phaseCompletionElapsedMilliseconds: {
				handshakeWorker: 250,
				pageApplication: 120,
				selectionContent: 700,
				sourceMetadata: 520,
			},
		});
	});

	test('uses the page-scoped tree witness with direct DOM paint proof for first Review', () => {
		const samples = [
			makeTelemetrySample({
				name: 'performance.bridge.viewer.time_to_first_interaction',
				viewer: 'review',
			}),
		];

		expect(
			bridgeCompleteJourneyTelemetryWitnessesSatisfied({
				activationSequence: null,
				samples,
				viewer: 'review',
			}),
		).toBe(true);
	});

	test('accepts a sequenced File tree witness from the exact fresh page attempt', () => {
		const samples = [
			makeTelemetrySample({
				activationSequence: 1,
				name: 'performance.bridge.viewer.time_to_first_interaction',
				viewer: 'file',
			}),
		];

		expect(
			bridgeCompleteJourneyTelemetryWitnessesSatisfied({
				activationSequence: null,
				samples,
				viewer: 'file',
			}),
		).toBe(true);
	});

	test('rejects stale or wrong-viewer witnesses for a Review switch', () => {
		const samples = [
			makeTelemetrySample({
				activationSequence: 8,
				name: 'performance.bridge.viewer.time_to_first_interaction',
				viewer: 'review',
			}),
			makeTelemetrySample({
				activationSequence: 9,
				name: 'performance.bridge.web.selected_content_painted',
				viewer: 'file',
			}),
		];

		expect(
			bridgeCompleteJourneyTelemetryWitnessesSatisfied({
				activationSequence: 9,
				samples,
				viewer: 'review',
			}),
		).toBe(false);
	});

	test('accepts File switch witnesses keyed by activation and demand request sequence', () => {
		const samples = [
			makeTelemetrySample({
				activationSequence: 17,
				name: 'performance.bridge.viewer.time_to_first_interaction',
				viewer: 'file',
			}),
			makeTelemetrySample({
				activationSequence: 17,
				activationSequenceAttribute: 'agentstudio.bridge.demand.request.sequence',
				name: 'performance.bridge.web.file_open_ready',
				viewer: 'file',
			}),
		];

		expect(
			bridgeCompleteJourneyTelemetryWitnessesSatisfied({
				activationSequence: 17,
				samples,
				viewer: 'file',
			}),
		).toBe(true);
	});

	test('selects exactly one new target activation and rejects ambiguous overlap', () => {
		const oneNewActivation = [
			makeTelemetrySample({
				activationSequence: 3,
				name: 'performance.bridge.web.viewer_activation',
				viewer: 'review',
			}),
			makeTelemetrySample({
				activationSequence: 4,
				name: 'performance.bridge.web.viewer_activation',
				viewer: 'file',
			}),
		];
		expect(
			bridgeCompleteJourneyActivationSequenceAfter({
				minimumExclusive: 3,
				samples: oneNewActivation,
				viewer: 'file',
			}),
		).toBe(4);

		const overlappingActivations = [
			...oneNewActivation,
			makeTelemetrySample({
				activationSequence: 5,
				name: 'performance.bridge.web.viewer_activation',
				viewer: 'file',
			}),
		];
		expect(() =>
			bridgeCompleteJourneyActivationSequenceAfter({
				minimumExclusive: 3,
				samples: overlappingActivations,
				viewer: 'file',
			}),
		).toThrow(/exactly one new File activation/u);
	});
});

function makeTelemetrySample(props: {
	readonly activationSequence?: number;
	readonly activationSequenceAttribute?:
		| 'agentstudio.bridge.activation.sequence'
		| 'agentstudio.bridge.demand.request.sequence';
	readonly name: string;
	readonly viewer: 'file' | 'review';
}): WorktreeBridgeTelemetrySampleProof {
	return {
		durationMilliseconds: 1,
		name: props.name,
		numericAttributes:
			props.activationSequence === undefined
				? {}
				: {
						[props.activationSequenceAttribute ?? 'agentstudio.bridge.activation.sequence']:
							props.activationSequence,
					},
		phase: null,
		result: 'success',
		slice: null,
		transport: 'content',
		viewer: props.viewer,
	};
}
