import type { ReactElement } from 'react';

import type { BridgeFileViewerSelectedCodeViewItem } from '../../file-viewer/bridge-file-viewer-code-view-items.js';
import { BridgeMarkdownCanvas, type BridgeMarkdownCanvasProps } from './bridge-markdown-canvas.js';
import type { BridgeMarkdownRenderIntent } from './use-bridge-markdown-presentation.js';
import { buildBridgeMarkdownRenderWorkerSuccessResponse } from './worker/bridge-markdown-render-worker-renderer.js';

export function fileItem(
	contents: string,
	version = 1,
	path = 'plan.md',
): BridgeFileViewerSelectedCodeViewItem {
	const itemId = path.replace(/\.md$/u, '');
	const cacheKey = `${itemId}:${version}`;
	return {
		id: `file:${itemId}`,
		type: 'file',
		version,
		file: { name: path, lang: 'markdown', cacheKey, contents },
		bridgeMetadata: {
			cacheKey,
			contentRoles: ['file'],
			contentState: 'hydrated',
			displayPath: path,
			itemId,
			lineCount: contents.split('\n').length,
			sourceDescriptorId: `${itemId}-descriptor-${version}`,
		},
	};
}

export function fileIntent(item: BridgeFileViewerSelectedCodeViewItem): BridgeMarkdownRenderIntent {
	return {
		sourceIdentity: {
			surface: 'file',
			sourceId: 'worktree',
			sourceGeneration: 1,
			fileId: item.bridgeMetadata.itemId,
			fileVersion: item.version ?? 0,
		},
		contentCacheKey: item.bridgeMetadata.cacheKey,
		contentHash: item.bridgeMetadata.cacheKey,
		sourcePath: item.bridgeMetadata.displayPath,
		markdownText: item.file.contents,
	};
}

export async function markdownCanvas(
	contents: string,
	version = 1,
	path = 'plan.md',
): Promise<ReactElement<BridgeMarkdownCanvasProps>> {
	const item = fileItem(contents, version, path);
	const intent = fileIntent(item);
	const response = await buildBridgeMarkdownRenderWorkerSuccessResponse({
		request: {
			...intent,
			schemaVersion: 1,
			method: 'markdown.render',
			requestId: `markdown-${version}`,
		},
	});
	return (
		<BridgeMarkdownCanvas
			isActive
			annotationSource={{ item }}
			retry={(): void => {}}
			presentationState={{
				status: 'ready',
				refresh: { kind: 'current' },
				identity: response,
				renderResult: response,
				sourcePath: path,
			}}
			renderFulfillment={{
				intent,
				selectedItem: item,
				coordinator: { observePostRender: (): void => {}, reconcilePublication: (): void => {} },
			}}
		/>
	);
}
