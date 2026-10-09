import { expect, test } from 'vitest';

import corpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeProductBatchFrameRouter } from './bridge-product-batch-frame-router.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';

const frames = corpus.transportV2.batchFrames
	.slice(0, 5)
	.map((frame) => bridgeProductBatchFrameSchema.parse(frame));

test.each(['payloadVerification', 'applicationInstall'] as const)(
	'%s failure keeps resnapshot behavior and reports its scrubbed cause',
	async (step) => {
		const diagnostics: unknown[] = [];
		let installs = 0;
		let resnapshots = 0;
		let endResnapshot: (() => void) | undefined;
		const ended = new Promise<void>((resolve): void => {
			endResnapshot = resolve;
		});
		const failure = new Error('Review bank rejected "/private/worktree/secret.swift"');
		const router = new BridgeProductBatchFrameRouter({
			deadlineClock: { schedule: (): (() => void) => (): void => {} },
			progressDeadlineMilliseconds: 100,
		});
		router.setSinks({
			diagnostic: (sample: unknown): void => {
				diagnostics.push(sample);
			},
			verify: (): void => {
				if (step === 'payloadVerification') throw failure;
			},
			install: (): Promise<void> => {
				installs += 1;
				return Promise.reject(failure);
			},
			receipt: (): void => {},
			resnapshot: (): void => {
				resnapshots += 1;
				endResnapshot?.();
			},
			resnapshotLatest: (): void => {},
		});
		try {
			for (const frame of frames) router.accept(frame);
			await ended;
			expect(resnapshots).toBe(1);
			expect(installs).toBe(step === 'payloadVerification' ? 0 : 1);
			expect(diagnostics).toContainEqual(
				expect.objectContaining({
					step,
					exception: { name: 'Error', message: 'Review bank rejected <value>' },
				}),
			);
		} finally {
			router.clear();
		}
	},
);

test('a part before its begin reports the receiver rejection without installing it', () => {
	const diagnostics: unknown[] = [];
	let resnapshots = 0;
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: { schedule: (): (() => void) => (): void => {} },
		progressDeadlineMilliseconds: 100,
	});
	router.setSinks({
		diagnostic: (sample: unknown): void => {
			diagnostics.push(sample);
		},
		install: (): never => {
			throw new Error('A rejected batch must not install');
		},
		receipt: (): void => {},
		resnapshot: (): void => {
			resnapshots += 1;
		},
		resnapshotLatest: (): void => {},
	});
	try {
		const part = frames[1];
		if (part === undefined) throw new Error('Missing corpus part');
		router.accept(part);
		expect(resnapshots).toBe(1);
		expect(diagnostics).toContainEqual(
			expect.objectContaining({
				step: 'receiverRejection',
				rejection: 'missingReceiver',
				exception: null,
			}),
		);
	} finally {
		router.clear();
	}
});

test('an observer failure cannot prevent the existing resnapshot', () => {
	let resnapshots = 0;
	const router = new BridgeProductBatchFrameRouter({
		deadlineClock: { schedule: (): (() => void) => (): void => {} },
		progressDeadlineMilliseconds: 100,
	});
	router.setSinks({
		diagnostic: (): never => {
			throw new Error('Diagnostic observer unavailable');
		},
		install: (): void => {},
		receipt: (): void => {},
		resnapshot: (): void => {
			resnapshots += 1;
		},
		resnapshotLatest: (): void => {},
	});
	try {
		const part = frames[1];
		if (part === undefined) throw new Error('Missing corpus part');
		expect(() => router.accept(part)).not.toThrow();
		expect(resnapshots).toBe(1);
	} finally {
		router.clear();
	}
});
