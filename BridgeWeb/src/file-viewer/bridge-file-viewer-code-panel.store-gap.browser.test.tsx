import { CodeView, type CodeViewOptions } from '@pierre/diffs';
import { act } from 'react';
import { expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the production Pierre canvas.
import '../app/bridge-app.css';
import { BridgeCommWorkerFileDisplayEventAuthority } from '../core/comm-worker/bridge-comm-worker-file-display-event-authority.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { createBridgeMainRenderSnapshotStore } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import { installBridgeProductFileBatch } from '../core/comm-worker/bridge-product-file-batch-installer.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../core/comm-worker/bridge-worker-render-fulfillment.js';
import { makeFileBatchInstallation } from '../core/comm-worker/comm-runtime-protocol.file-product.test-support.js';
import { bridgeCodeViewPresentationItemHasExactSource } from '../review-viewer/code-view/bridge-code-view-render-fulfillment.js';
import { createWorktreeAnnotationBrowserProviderHarness } from '../worktree-annotations/worktree-annotation-browser-test-support.js';
import {
	BridgeFileViewerCodePanel,
	type BridgeFileViewerCodePanelState,
} from './bridge-file-viewer-code-panel.js';
import { makeFilePublication } from './bridge-file-viewer-render-fulfillment.test-support.js';
import { applyBridgeWorkerMessagesToFileViewerRenderSnapshotStore } from './bridge-file-viewer-render-snapshot-controller.js';

test('paints publication 21 on the retained Pierre owner after publication 14 leaves the real store', async () => {
	const store = createBridgeMainRenderSnapshotStore();
	const annotationHarness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const receipts = new EventWitness<BridgeWorkerRenderDispositionReceipt>();
	const frames = new EventWitness<FrameRequestCallback>();
	const postRenders = new EventWitness<string>();
	const owners: CodeView[] = [];
	// oxlint-disable-next-line unbound-method -- Restore the public prototype witness in finally.
	const originalSetup = CodeView.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Restore the public prototype witness in finally.
	const originalSetOptions = CodeView.prototype.setOptions;
	CodeView.prototype.setup = function captureOwner(root: HTMLElement): void {
		owners.push(this);
		originalSetup.call(this, root);
	};
	CodeView.prototype.setOptions = function capturePostRender(
		options: CodeViewOptions<undefined> | undefined,
	): void {
		const callback = options?.onPostRender;
		originalSetOptions.call(
			this,
			callback === undefined
				? options
				: {
						...options,
						onPostRender: (element, instance, phase, context): void => {
							Reflect.apply(callback, undefined, [element, instance, phase, context]);
							if (context.item.type === 'file')
								postRenders.record(context.item.file.cacheKey ?? '');
						},
					},
		);
	};
	let frameHandle = 0;
	const coordinator = createBridgeMainRenderFulfillmentCoordinator({
		cancelAnimationFrame: (): void => {},
		nowMilliseconds: (): number => 1000,
		requestAnimationFrame: (callback): number => {
			frames.record(callback);
			return ++frameHandle;
		},
		sendDisposition: (receipt): void => receipts.record(receipt),
	});
	const selection = { fileId: 'file-1', path: 'src/a.ts' };
	const applyMessages = (
		messages: Parameters<
			typeof applyBridgeWorkerMessagesToFileViewerRenderSnapshotStore
		>[0]['messages'],
	): void => {
		applyBridgeWorkerMessagesToFileViewerRenderSnapshotStore({
			messages,
			renderFulfillmentCoordinator: coordinator,
			renderSnapshotStore: store,
			selection,
		});
	};
	const view = installBridgeProductFileBatch(makeFileBatchInstallation('store-gap'));
	const authority = new BridgeCommWorkerFileDisplayEventAuthority({
		createSequence: (): number => 1,
	});
	applyMessages(authority.publish({ epoch: 1, patches: view.displayPatches }));
	store.setLocalSelection({ selectedItemId: selection.fileId, source: 'user' });
	expect(store.getSnapshot().fileDisplayFreshness?.epoch).toBe(1);
	const first = makeFilePublication({
		contentsMarker: 'publication-14',
		path: selection.path,
		publicationSequence: 14,
		version: 14,
	});
	applyMessages([first]);
	const firstItem = store.getSnapshot().codeViewItemsById[selection.fileId];
	if (firstItem?.type !== 'file') throw new Error('Expected publication 14 in the real store.');
	const panelProps = {
		codeViewWorkerPoolEnabled: false,
		openFileState: {
			displayItem: null,
			...selection,
			status: 'ready',
		} satisfies BridgeFileViewerCodePanelState,
		renderFulfillmentCoordinator: coordinator,
		selectedCodeViewItem: firstItem,
		totalHeightPixels: null,
	};
	try {
		const rendered = await render(
			annotationHarness.wrap(<BridgeFileViewerCodePanel {...panelProps} />),
		);
		await postRenders.waitFor((key): boolean => key === firstItem.file.cacheKey);
		await receipts.waitFor(
			(receipt): boolean => receipt.publicationSequence === 14 && receipt.disposition === 'applied',
		);
		const paintFirst = await frames.waitFor((): boolean => true);
		paintFirst(1000);
		await receipts.waitFor(
			(receipt): boolean => receipt.publicationSequence === 14 && receipt.disposition === 'painted',
		);
		const owner = owners[0];
		if (owner === undefined) throw new Error('Expected a mounted Pierre owner.');
		const firstVersion = owner.getItem(firstItem.id)?.version;
		expect(firstVersion).toBe(1);

		// Control: selected-applier normalization preserves the current selected copy.
		applyMessages([
			{
				direction: 'serverWorkerToMain',
				kind: 'fileRenderPatch',
				patches: [{ itemId: selection.fileId, operation: 'delete', slice: 'rowPaint' }],
				publicationSequence: 15,
				surface: 'file',
				transferDescriptors: [],
				wireVersion: 1,
				workerDerivationEpoch: 1,
			},
		]);
		expect(store.getSnapshot().codeViewItemsById[selection.fileId]).toBe(firstItem);

		// Actual store invalidation is independent of the mounted panel's retained presentation.
		store.applySnapshotUpdate({
			workerPatches: [{ itemId: selection.fileId, operation: 'delete', slice: 'rowPaint' }],
		});
		expect(store.getSnapshot().codeViewItemsById[selection.fileId]).toBeUndefined();
		await act(async (): Promise<void> => {
			await rendered.rerender(
				annotationHarness.wrap(
					<BridgeFileViewerCodePanel
						{...panelProps}
						openFileState={{ ...panelProps.openFileState, status: 'loading' }}
						selectedCodeViewItem={null}
					/>,
				),
			);
		});
		expect(owner.getItem(firstItem.id)).toBe(firstItem);

		const second = makeFilePublication({
			contentsMarker: 'publication-21',
			path: selection.path,
			publicationSequence: 21,
			version: 21,
		});
		applyMessages([second]);
		const secondItem = store.getSnapshot().codeViewItemsById[selection.fileId];
		if (secondItem?.type !== 'file') throw new Error('Expected publication 21 in the real store.');
		expect(secondItem.version).toBe(1);
		await act(async (): Promise<void> => {
			await rendered.rerender(
				annotationHarness.wrap(
					<BridgeFileViewerCodePanel {...panelProps} selectedCodeViewItem={secondItem} />,
				),
			);
		});
		const currentItem = owner.getItem(secondItem.id);
		expect(currentItem?.version).toBeGreaterThan(firstVersion ?? 0);
		expect(bridgeCodeViewPresentationItemHasExactSource(currentItem, secondItem)).toBe(true);
		await postRenders.waitFor((key): boolean => key === secondItem.file.cacheKey);
		await receipts.waitFor(
			(receipt): boolean => receipt.publicationSequence === 21 && receipt.disposition === 'applied',
		);
		const paintSecond = await frames.waitFor((callback): boolean => callback !== paintFirst);
		paintSecond(1001);
		await receipts.waitFor(
			(receipt): boolean => receipt.publicationSequence === 21 && receipt.disposition === 'painted',
		);
		const currentRendered = owner
			.getRenderedItems()
			.find((item): boolean => item.id === secondItem.id);
		expect(currentRendered?.element.getAttribute('data-bridge-painted-publication-id')).toBe(
			second.renderReceiptIdentity.publicationId,
		);
		expect(owners).toEqual([owner]);
	} finally {
		await cleanup();
		coordinator.dispose();
		store.dispose();
		CodeView.prototype.setup = originalSetup;
		CodeView.prototype.setOptions = originalSetOptions;
	}
});

class EventWitness<TEvent> {
	private readonly events: TEvent[] = [];
	private readonly waiters: {
		readonly matches: (event: TEvent) => boolean;
		readonly resolve: (event: TEvent) => void;
	}[] = [];
	record(event: TEvent): void {
		this.events.push(event);
		for (const waiter of this.waiters.slice()) {
			if (!waiter.matches(event)) continue;
			this.waiters.splice(this.waiters.indexOf(waiter), 1);
			waiter.resolve(event);
		}
	}
	waitFor(matches: (event: TEvent) => boolean): Promise<TEvent> {
		const event = this.events.find(matches);
		if (event !== undefined) return Promise.resolve(event);
		return new Promise((resolve): void => {
			this.waiters.push({ matches, resolve });
		});
	}
}
