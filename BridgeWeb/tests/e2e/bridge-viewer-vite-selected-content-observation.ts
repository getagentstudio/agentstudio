import type { ConsoleMessage, Page } from 'playwright';

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
export async function installSelectedContentOwnerObservation(page: Page): Promise<{
	readonly readRetained: () => unknown;
	readonly dispose: () => void;
}> {
	let retained: unknown = null;
	const prefix = '__bridge_selected_content_owner_snapshot:';
	const retain = (message: ConsoleMessage): void => {
		const text = message.text();
		if (!text.startsWith(prefix)) return;
		try {
			retained = JSON.parse(text.slice(prefix.length));
		} catch {
			// A malformed optional diagnostic cannot affect the journey or erase prior facts.
		}
	};
	page.on('console', retain);
	try {
		await page.addInitScript({
			content: `(() => {
		const createRecorder = (${createSelectedContentOwnerRecorder.toString()});
		const classify = (${selectedContentTerminalFailure.toString()});
		const recorder = createRecorder(classify);
		const NativeMessageChannel = window.MessageChannel;
		const releases = [];
		let channelId = 0;
		let disposed = false;
		let lastSnapshot = '';
		const changed = () => {
			const snapshot = JSON.stringify({ file: recorder.read('file'), review: recorder.read('review') });
			if (snapshot !== lastSnapshot) {
				lastSnapshot = snapshot;
				console.debug(${JSON.stringify(prefix)} + snapshot);
			}
			document.dispatchEvent(new Event('__bridge_selected_content_owner_changed'));
		};
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
	} catch (error: unknown) {
		page.off('console', retain);
		throw error;
	}
	return {
		readRetained: (): unknown => retained,
		dispose: (): void => {
			page.off('console', retain);
		},
	};
}

export async function readSelectedContentOwnerObservation(page: Page): Promise<unknown> {
	return page.evaluate(() => ({
		file: window.bridgeSelectedContentOwnerObservation?.read('file') ?? null,
		review: window.bridgeSelectedContentOwnerObservation?.read('review') ?? null,
	}));
}
