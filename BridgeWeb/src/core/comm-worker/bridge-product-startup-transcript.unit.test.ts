import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, test } from 'vitest';
import { z } from 'zod';

import {
	bridgeProductContentHeaderSchema,
	bridgeProductContentRequestSchema,
} from './bridge-product-content-contracts.js';
import { bridgeProductFrameAcknowledgementRequestSchema } from './bridge-product-frame-acknowledgement-contracts.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	bridgeProductMetadataFrameSchema,
	bridgeProductMetadataStreamRequestSchema,
} from './bridge-product-session-contracts.js';

const transcriptCodecSchema = z.enum([
	'contentHeader',
	'contentRequest',
	'controlRequest',
	'controlResponse',
	'metadataFrame',
	'metadataStreamRequest',
]);
const observationDispositionSchema = z.enum([
	'accepted',
	'idempotentReplay',
	'rejectedChangedReuse',
	'rejectedForeignIdentity',
	'rejectedPostTerminal',
	'rejectedSequenceGap',
	'rejectedStaleWorker',
]);
const validStartupTranscriptSchema = z
	.object({
		lifecycleExpectations: z
			.object({
				cancel: z
					.object({
						requestId: z.string().min(1),
						subscriptionId: z.string().min(1),
						terminalFrameKind: z.literal('subscription.cancelled'),
					})
					.strict(),
				replacement: z
					.object({
						replacementWorkerInstanceId: z.string().min(1),
						retiredWorkerInstanceId: z.string().min(1),
						staleObservationCase: z.string().min(1),
					})
					.strict(),
				zeroResidue: z
					.object({
						leases: z.literal(0),
						producers: z.literal(0),
						responses: z.literal(0),
						retainedBodies: z.literal(0),
						sessions: z.literal(0),
						subscriptions: z.literal(0),
						waiters: z.literal(0),
					})
					.strict(),
			})
			.strict(),
		observationCases: z.array(
			z
				.object({
					expectedDisposition: observationDispositionSchema,
					name: z.string().min(1),
					request: z.unknown(),
				})
				.strict(),
		),
		envelopeTranscript: z.array(
			z
				.object({
					codec: z.enum([
						'operationAdmittedResponse',
						'operationResultRequest',
						'operationResultResponse',
						'operationResultAcknowledgement',
					]),
					name: z.string().min(1),
					value: z.unknown(),
				})
				.strict(),
		),
		schemaVersion: z.literal(1),
		transcript: z.array(
			z
				.object({
					codec: transcriptCodecSchema,
					name: z.string().min(1),
					payloadBase64: z.string().optional(),
					value: z.unknown(),
				})
				.strict(),
		),
		wireVersion: z.literal(2),
	})
	.strict();
const invalidStartupTranscriptSchema = z
	.object({
		cases: z.array(
			z
				.object({
					name: z.string().min(1),
					request: z.unknown(),
				})
				.strict(),
		),
		schemaVersion: z.literal(1),
		wireVersion: z.literal(2),
	})
	.strict();

const frozenFixtureHashes = {
	invalid: 'e51803d06d8dafd56d6c694569ed238bb3dd8bddadfec6d26b2834b5d5892a68',
	valid: '29ddcc6601f7b531f637cf9a3c57a1dbdeee6dcc9e60087218ea951c7edc4498',
} as const;

describe('Bridge product startup transcript', () => {
	test('keeps the Swift source and TypeScript mirrors byte-identical', () => {
		// Arrange
		const fixtureKinds = ['invalid', 'valid'] as const;

		// Act
		const fixtureIdentities = fixtureKinds.map((fixtureKind) => {
			const sourceBytes = readFixtureBytes(
				`../../../../Tests/BridgeContractFixtures/${fixtureKind}/bridge-product-startup-transcript.json`,
			);
			const mirrorBytes = readFixtureBytes(
				`../../test-fixtures/bridge-contract-fixtures/${fixtureKind}/bridge-product-startup-transcript.json`,
			);
			return {
				fixtureKind,
				mirrorBytes,
				observedHash: createHash('sha256').update(sourceBytes).digest('hex'),
				sourceBytes,
			};
		});

		// Assert
		for (const fixtureIdentity of fixtureIdentities) {
			expect(fixtureIdentity.sourceBytes.equals(fixtureIdentity.mirrorBytes)).toBe(true);
			expect(fixtureIdentity.observedHash).toBe(frozenFixtureHashes[fixtureIdentity.fixtureKind]);
		}
	});

	test('decodes every already-supported startup and event structure', () => {
		// Arrange
		const fixture = loadValidFixture();

		// Act / Assert
		expect(fixture.transcript).toHaveLength(21);
		for (const entry of fixture.transcript) {
			switch (entry.codec) {
				case 'contentHeader':
					expect(bridgeProductContentHeaderSchema.parse(entry.value), entry.name).toEqual(
						entry.value,
					);
					break;
				case 'contentRequest':
					expect(bridgeProductContentRequestSchema.parse(entry.value), entry.name).toEqual(
						entry.value,
					);
					break;
				case 'controlRequest': {
					expect(bridgeProductControlRequestSchema.parse(entry.value), entry.name).toEqual(
						entry.value,
					);
					break;
				}
				case 'controlResponse': {
					expect(bridgeProductControlResponseSchema.parse(entry.value), entry.name).toEqual(
						entry.value,
					);
					break;
				}
				case 'metadataFrame':
					expect(bridgeProductMetadataFrameSchema.parse(entry.value), entry.name).toEqual(
						entry.value,
					);
					break;
				case 'metadataStreamRequest': {
					expect(bridgeProductMetadataStreamRequestSchema.parse(entry.value), entry.name).toEqual(
						entry.value,
					);
					break;
				}
			}
		}
	});

	test('accepts cumulative content credit and rejects retired metadata observations', () => {
		// Arrange
		const fixture = loadValidFixture();
		const contentCases = fixture.observationCases.filter(
			(observationCase) => observationStreamKind(observationCase.request) === 'content',
		);
		const metadataCases = loadInvalidFixture().cases.filter(
			(observationCase) => observationStreamKind(observationCase.request) === 'metadata',
		);

		// Act
		const contentParseResults = contentCases.map((observationCase) => ({
			name: observationCase.name,
			result: bridgeProductFrameAcknowledgementRequestSchema.safeParse(observationCase.request),
		}));
		const metadataParseResults = metadataCases.map((observationCase) =>
			bridgeProductFrameAcknowledgementRequestSchema.safeParse(observationCase.request),
		);

		// Assert
		for (const parseResult of contentParseResults) {
			expect(parseResult.result.success, parseResult.name).toBe(true);
		}
		expect(metadataParseResults).toHaveLength(4);
		expect(metadataParseResults.every((result) => !result.success)).toBe(true);
	});

	test('rejects every structurally hostile observation body', () => {
		// Arrange
		const fixture = loadInvalidFixture();

		// Act
		const parseResults = fixture.cases.map((fixtureCase) => ({
			name: fixtureCase.name,
			result: bridgeProductFrameAcknowledgementRequestSchema.safeParse(fixtureCase.request),
		}));

		// Assert
		expect(parseResults).toHaveLength(10);
		for (const parseResult of parseResults) {
			expect(parseResult.result.success, parseResult.name).toBe(false);
		}
	});
});

function loadValidFixture(): z.infer<typeof validStartupTranscriptSchema> {
	const bytes = readFixtureBytes(
		'../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-startup-transcript.json',
	);
	const parsedJSON: unknown = JSON.parse(bytes.toString('utf8'));
	return validStartupTranscriptSchema.parse(parsedJSON);
}

function loadInvalidFixture(): z.infer<typeof invalidStartupTranscriptSchema> {
	const bytes = readFixtureBytes(
		'../../test-fixtures/bridge-contract-fixtures/invalid/bridge-product-startup-transcript.json',
	);
	const parsedJSON: unknown = JSON.parse(bytes.toString('utf8'));
	return invalidStartupTranscriptSchema.parse(parsedJSON);
}

function readFixtureBytes(relativePath: string): Buffer {
	return readFileSync(new URL(relativePath, import.meta.url));
}

function observationStreamKind(value: unknown): string | undefined {
	if (typeof value !== 'object' || value === null) {
		return undefined;
	}
	if ('kind' in value && value.kind === 'content.acknowledge') return 'content';
	if (!('streamKind' in value)) return undefined;
	return typeof value.streamKind === 'string' ? value.streamKind : undefined;
}
