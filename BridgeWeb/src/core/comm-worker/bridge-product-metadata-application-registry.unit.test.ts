import { describe, expect, test } from 'vitest';
import { z } from 'zod';

import {
	defineBridgeProductMetadataApplicationProtocol,
	BridgeProductMetadataApplicationRegistry,
	registerBridgeProductMetadataApplicationProtocol,
} from './bridge-product-metadata-application-protocol.js';
import {
	bridgeProductFileAnnotationMetadataApplicationProtocol,
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductMetadataApplicationRegistry,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';

const fixtureProtocol = defineBridgeProductMetadataApplicationProtocol({
	initialOpen: (options) => ({ source: options.source, subscriptionKind: 'fixture.metadata' }),
	kind: 'fixture.metadata',
	openSchema: z
		.object({ source: z.string(), subscriptionKind: z.literal('fixture.metadata') })
		.strict(),
	optionsSchema: z.object({ source: z.string() }).strict(),
	surface: 'file',
});

describe('Bridge product metadata application registry', () => {
	test('registers and validates the lifecycle open contract', () => {
		const registry = new BridgeProductMetadataApplicationRegistry([
			registerBridgeProductMetadataApplicationProtocol(fixtureProtocol),
		]);

		expect(registry.lookup('fixture.metadata')).toBe(fixtureProtocol);
		expect(
			registry.validateOpen('fixture.metadata', fixtureProtocol.initialOpen({ source: 's1' })),
		).toEqual({
			source: 's1',
			subscriptionKind: 'fixture.metadata',
		});
		expect(() => fixtureProtocol.optionsSchema.parse({ source: 's1', interests: [] })).toThrow();
	});

	test('rejects duplicate registration and unknown or mismatched protocol lookup', () => {
		expect(
			() =>
				new BridgeProductMetadataApplicationRegistry([
					registerBridgeProductMetadataApplicationProtocol(fixtureProtocol),
					registerBridgeProductMetadataApplicationProtocol(fixtureProtocol),
				]),
		).toThrow(/[Dd]uplicate/u);

		const registry = new BridgeProductMetadataApplicationRegistry([
			registerBridgeProductMetadataApplicationProtocol(fixtureProtocol),
		]);
		expect(() => registry.lookup('unknown.metadata')).toThrow(/unknown/u);
		expect(() => registry.requireProtocol(bridgeProductFileMetadataApplicationProtocol)).toThrow(
			/[Uu]nregistered/u,
		);
	});

	test('installs exactly the four current File and Review lifecycle protocols', () => {
		expect(bridgeProductMetadataApplicationRegistry.registeredKinds).toEqual([
			'file.annotations',
			'file.metadata',
			'review.annotations',
			'review.metadata',
		]);
		expect(bridgeProductMetadataApplicationRegistry.lookup('file.annotations')).toBe(
			bridgeProductFileAnnotationMetadataApplicationProtocol,
		);
		expect(bridgeProductMetadataApplicationRegistry.lookup('file.metadata')).toBe(
			bridgeProductFileMetadataApplicationProtocol,
		);
		expect(bridgeProductMetadataApplicationRegistry.lookup('review.annotations')).toBe(
			bridgeProductReviewAnnotationMetadataApplicationProtocol,
		);
		expect(bridgeProductMetadataApplicationRegistry.lookup('review.metadata')).toBe(
			bridgeProductReviewMetadataApplicationProtocol,
		);
	});
});
