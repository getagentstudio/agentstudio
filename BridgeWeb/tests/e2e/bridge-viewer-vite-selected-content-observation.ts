import type { Page } from 'playwright';

import {
	createSelectedContentOwnerRecorder,
	selectedContentTerminalFailure,
	type SelectedContentOwnerSnapshot,
} from './bridge-viewer-vite-selected-content-owner.ts';

declare global {
	interface Window {
		bridgeSelectedContentOwnerObservation?: {
			readonly read: (surface: 'file' | 'review') => SelectedContentOwnerSnapshot;
			readonly dispose: () => void;
		};
	}
}

/** Observe the existing product port unchanged, before bootstrap/selection can be sent. */
export async function installSelectedContentOwnerObservation(page: Page): Promise<void> {
	await page.addInitScript({
		content: `(() => {
		const createRecorder = (${createSelectedContentOwnerRecorder.toString()});
		const classify = (${selectedContentTerminalFailure.toString()});
		const recorder = createRecorder(classify);
		const NativeMessageChannel = window.MessageChannel;
		const releases = [];
		let channelId = 0;
		let disposed = false;
		const changed = () => document.dispatchEvent(new Event('__bridge_selected_content_owner_changed'));
		class ObservedSelectedContentChannel extends NativeMessageChannel {
			constructor() {
				super();
				const observedChannelId = ++channelId;
				const port = this.port2;
				const observe = event => {
					if (disposed) return;
					recorder.observe(observedChannelId, event.data);
					changed();
				};
				port.addEventListener('message', observe);
				const post = port.postMessage;
				const observedPost = function(message, options) {
					// Observation cannot detach payloads, reorder delivery, or start/close the port.
					post.call(port, message, options);
					if (!disposed) { recorder.observe(observedChannelId, message); changed(); }
				};
				port.postMessage = observedPost;
				releases.push(() => {
					port.removeEventListener('message', observe);
					if (port.postMessage === observedPost) port.postMessage = post;
				});
			}
		}
		const dispose = () => {
			if (disposed) return;
			disposed = true;
			for (const release of releases.splice(0)) release();
			if (window.MessageChannel === ObservedSelectedContentChannel) window.MessageChannel = NativeMessageChannel;
		};
		window.MessageChannel = ObservedSelectedContentChannel;
		window.bridgeSelectedContentOwnerObservation = { read: recorder.read, dispose };
		window.addEventListener('pagehide', dispose, { once: true });
	})()`,
	});
}

export async function readSelectedContentOwnerObservation(page: Page): Promise<unknown> {
	return page.evaluate(() => ({
		file: window.bridgeSelectedContentOwnerObservation?.read('file') ?? null,
		review: window.bridgeSelectedContentOwnerObservation?.read('review') ?? null,
	}));
}
