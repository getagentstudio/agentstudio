import { expect, test } from 'vitest';

import {
	bridgeCodeViewPresentationItemHasExactSource,
	bridgeCodeViewPresentationItemWithExactSource,
} from '../review-viewer/code-view/bridge-code-view-render-fulfillment.js';
import { bridgeFileViewerCodeViewItemsForPanelState } from './bridge-file-viewer-code-view-items.js';
import {
	BridgeFileViewerPresentationVersions,
	type BridgeFileViewerPresentationItem,
} from './bridge-file-viewer-presentation-versions.js';
import { makeFilePublication } from './bridge-file-viewer-render-fulfillment.test-support.js';

test('unchanged annotation composition keeps its presentation while source and annotation changes advance versions', () => {
	const versions = new BridgeFileViewerPresentationVersions();
	const firstPublication = makeFilePublication({
		contentsMarker: 'old-source',
		publicationSequence: 14,
		version: 1,
	}).job.payload.item;
	const secondPublication = makeFilePublication({
		contentsMarker: 'new-source',
		publicationSequence: 21,
		version: 1,
	}).job.payload.item;
	const firstSource = exactFileItem(firstPublication);
	const secondSource = exactFileItem(secondPublication);
	const composeAnnotations = (version: number): BridgeFileViewerPresentationItem =>
		bridgeCodeViewPresentationItemWithExactSource({
			presentationItem: { ...firstSource, annotations: [], version },
			sourceItem: firstSource,
		});
	const annotated = versions.preparePresentationItem(composeAnnotations(1_000_001), firstSource);
	expect(versions.preparePresentationItem(composeAnnotations(1_000_001), firstSource)).toBe(
		annotated,
	);
	const changedAnnotations = versions.preparePresentationItem(
		composeAnnotations(1_000_002),
		firstSource,
	);
	expect(changedAnnotations.version).toBeGreaterThan(annotated.version ?? 0);
	const replacement = versions.preparePresentationItem(secondSource);
	expect(replacement.version).toBeGreaterThan(changedAnnotations.version ?? 0);
	expect(bridgeCodeViewPresentationItemHasExactSource(replacement, secondSource)).toBe(true);
	expect(versions.preparePresentationItem(secondSource)).toBe(replacement);
	const revisited = versions.preparePresentationItem(firstSource);
	expect(revisited.version).toBeGreaterThan(replacement.version ?? 0);
	expect(bridgeCodeViewPresentationItemHasExactSource(revisited, firstSource)).toBe(true);
});

function exactFileItem(
	publicationItem: ReturnType<typeof makeFilePublication>['job']['payload']['item'],
): BridgeFileViewerPresentationItem {
	if (publicationItem.type !== 'file') throw new Error('Expected a File publication.');
	const [item] = bridgeFileViewerCodeViewItemsForPanelState({
		openFileState: {
			displayItem: null,
			fileId: publicationItem.bridgeMetadata.itemId,
			path: publicationItem.bridgeMetadata.displayPath,
			status: 'ready',
		},
		selectedCodeViewItem: publicationItem,
	});
	if (item === undefined) throw new Error('Expected a valid Pierre File item.');
	return item;
}
