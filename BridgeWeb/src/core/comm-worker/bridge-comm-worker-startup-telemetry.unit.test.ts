import { describe, expect, test, vi } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryWorkerEventProducer } from '../telemetry-worker/bridge-telemetry-worker-event-adapter.js';
import { BridgeCommWorkerStartupTelemetryBuffer } from './bridge-comm-worker-startup-telemetry.js';

describe('Bridge comm worker startup telemetry', () => {
	test('preserves required samples and reports bounded overflow in source order', () => {
		const buffer = new BridgeCommWorkerStartupTelemetryBuffer();
		buffer.configure({ maximumBytes: 4096, maximumSamples: 1 });
		buffer.record(sample('first', 'hot'));
		buffer.record(sample('second', 'hot'));
		buffer.record(sample('optional', 'best_effort'));
		const received: unknown[] = [];
		const producer: BridgeTelemetryWorkerEventProducer = {
			isEnabled: (): boolean => true,
			record: vi.fn(),
			recordCompact: (compact): void => {
				received.push(compact);
			},
			recordPriorLoss: (loss): void => {
				received.push(loss);
			},
			close: vi.fn(),
		};

		buffer.drainInto(producer);

		expect(received).toMatchObject([
			{ type: 'event.required', sample: { name: 'first' } },
			{ requiredCount: 1, optionalCount: 1, reason: 'queue_saturated' },
		]);
	});

	test('caps encoded bytes and records the dropped required sample', () => {
		const buffer = new BridgeCommWorkerStartupTelemetryBuffer();
		buffer.configure({ maximumBytes: 1, maximumSamples: 2 });
		buffer.record(sample('too-large', 'hot'));
		const recordPriorLoss = vi.fn();
		buffer.drainInto({
			isEnabled: (): boolean => true,
			record: vi.fn(),
			recordCompact: vi.fn(),
			recordPriorLoss,
			close: vi.fn(),
		});
		expect(recordPriorLoss).toHaveBeenCalledWith({
			requiredCount: 1,
			optionalCount: 0,
			reason: 'encoded_byte_cap',
		});
	});
});

function sample(name: string, priority: 'hot' | 'best_effort'): BridgeTelemetrySample {
	return {
		scope: 'web',
		name,
		durationMilliseconds: null,
		traceContext: null,
		stringAttributes: { 'agentstudio.bridge.priority': priority },
		numericAttributes: {},
		booleanAttributes: {},
	};
}
