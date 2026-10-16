import { uuidv7 } from 'uuidv7';
import { expect, test } from 'vitest';

import {
	bridgePageRunCommandRequestSchema,
	readBridgePageReloadCommandDisplay,
} from './bridge-page-command-surface.js';

const reloadDisplay = {
	command: 'reloadBridgeWebView',
	label: 'Reload Bridge',
	helpText: 'Reload this pane',
	icon: 'arrow.clockwise',
} as const;

function commandTarget(pageCommands: unknown): EventTarget {
	const target = new EventTarget();
	target.addEventListener('__bridge_handshake_request', (): void => {
		target.dispatchEvent(new CustomEvent('__bridge_handshake', { detail: { pageCommands } }));
	});
	return target;
}

test('reads the catalog reload command without product configuration or bootstrap', () => {
	const target = commandTarget([reloadDisplay]);
	let bootstrapRequests = 0;
	target.addEventListener('__bridge_product_session_bootstrap_request', (): void => {
		bootstrapRequests += 1;
	});
	expect(readBridgePageReloadCommandDisplay(target)).toEqual(reloadDisplay);
	expect(bootstrapRequests).toBe(0);
});

test('rejects open command surfaces and malformed catalog projections', () => {
	for (const invalidCommands of [
		[],
		[{ ...reloadDisplay, command: 'showBridgeFiles' }],
		[{ ...reloadDisplay, icon: 'unknown' }],
		[{ ...reloadDisplay, label: '' }],
		[{ ...reloadDisplay, helpText: '' }],
		[{ ...reloadDisplay, extra: true }],
		[reloadDisplay, reloadDisplay],
		null,
	]) {
		expect(readBridgePageReloadCommandDisplay(commandTarget(invalidCommands))).toBeNull();
	}
	expect(readBridgePageReloadCommandDisplay(new EventTarget())).toBeNull();
});

test('the pre-session request admits only pane reload with a UUIDv7 correlation', () => {
	const request = { command: 'reloadBridgeWebView', requestId: uuidv7() };
	expect(bridgePageRunCommandRequestSchema.parse(request)).toEqual(request);
	for (const invalidRequest of [
		{ ...request, command: 'showBridgeFiles' },
		{ ...request, requestId: '' },
		{ ...request, paneId: uuidv7() },
	]) {
		expect(bridgePageRunCommandRequestSchema.safeParse(invalidRequest).success).toBe(false);
	}
});
