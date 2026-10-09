import {
	makeBridgeContentHandle,
	makeBridgeReviewItem,
} from '../../foundation/review-package/bridge-review-package-test-support.js';
import type {
	BridgeContentHandle,
	BridgeContentRole,
	BridgeFileChangeKind,
	BridgeFileClass,
	BridgeReviewItemDescriptor,
} from '../../foundation/review-package/bridge-review-package.js';
import type { BridgeViewerBrowserFixtureClass } from './bridge-viewer-mocked-backend-fixture.js';

export function primaryPathForItem(item: BridgeReviewItemDescriptor): string {
	return item.headPath ?? item.basePath ?? item.itemId;
}

export function makeBrowserFixtureItem(props: {
	readonly itemId: string;
	readonly path: string;
	readonly itemKind?: BridgeReviewItemDescriptor['itemKind'];
	readonly changeKind: BridgeFileChangeKind;
	readonly fileClass: BridgeFileClass;
	readonly language: string;
	readonly extension: string;
}): BridgeReviewItemDescriptor {
	const baseItem = makeBridgeReviewItem({ itemId: props.itemId, path: props.path });
	const base =
		props.changeKind === 'added'
			? null
			: makeBrowserContentHandle(props.itemId, 'base', props.language, props.extension);
	const head =
		props.changeKind === 'deleted'
			? null
			: makeBrowserContentHandle(props.itemId, 'head', props.language, props.extension);
	return {
		...baseItem,
		itemKind: props.itemKind ?? baseItem.itemKind,
		itemId: props.itemId,
		basePath: props.changeKind === 'added' ? null : props.path,
		headPath: props.changeKind === 'deleted' ? null : props.path,
		changeKind: props.changeKind,
		fileClass: props.fileClass,
		language: props.language,
		extension: props.extension,
		baseContentHash: base?.contentHash ?? null,
		headContentHash: head?.contentHash ?? null,
		additions: props.changeKind === 'deleted' ? 0 : 7,
		deletions: props.changeKind === 'added' ? 0 : 4,
		contentRoles: { base, head, diff: null, file: null },
		cacheKey: `${base?.cacheKey ?? 'none'}|${head?.cacheKey ?? 'none'}`,
		isHiddenByDefault: false,
		hiddenReason: null,
	};
}

export function makeBrowserFillerItem(props: {
	readonly fixtureClass: BridgeViewerBrowserFixtureClass;
	readonly index: number;
}): BridgeReviewItemDescriptor {
	const pathRoot = props.fixtureClass === 'small-mixed' ? 'tree' : 'Sources/AgentStudio';
	const pathLeaf = props.index.toString().padStart(3, '0');
	const moduleName = Math.floor(props.index / 12)
		.toString()
		.padStart(2, '0');
	const fileClass = browserFillerFileClass(props.index);
	const changeKind = browserFillerChangeKind(props.index);
	const extension = fileClass === 'docs' ? 'md' : 'ts';
	const language = fileClass === 'docs' ? 'markdown' : 'typescript';
	const path =
		props.fixtureClass === 'small-mixed'
			? `tree/module-${moduleName}/file-${pathLeaf}.${extension}`
			: `${pathRoot}/${fileClass}/module-${moduleName}/file-${pathLeaf}.${extension}`;
	return makeBrowserFixtureItem({
		itemId: `browser-filler-${props.fixtureClass}-${pathLeaf}`,
		path,
		changeKind,
		fileClass,
		language,
		extension,
	});
}

export function fillerItemCountForFixtureClass(
	fixtureClass: BridgeViewerBrowserFixtureClass,
): number {
	switch (fixtureClass) {
		case 'small-mixed':
			return 96;
		case 'medium-agentstudio':
			return 1_000;
		case 'large-diffshub':
			return 3_414;
	}
	const exhaustiveFixtureClass: never = fixtureClass;
	void exhaustiveFixtureClass;
	throw new Error('Unhandled fixture class');
}

export function browserFillerFileClass(index: number): BridgeFileClass {
	if (index % 23 === 0) {
		return 'docs';
	}
	if (index % 17 === 0) {
		return 'config';
	}
	if (index % 7 === 0) {
		return 'test';
	}
	return 'source';
}

export function browserFillerChangeKind(index: number): BridgeFileChangeKind {
	if (index % 29 === 0) {
		return 'renamed';
	}
	if (index % 31 === 0) {
		return 'deleted';
	}
	if (index % 5 === 0) {
		return 'added';
	}
	return 'modified';
}

export function makeBrowserContentHandle(
	itemId: string,
	role: 'base' | 'head',
	language: string,
	extension: string,
): BridgeContentHandle {
	const handle = makeBridgeContentHandle(itemId, role);
	return {
		...handle,
		reviewGeneration: 338,
		mimeType: extension === 'md' ? 'text/markdown' : 'text/typescript',
		language,
		sizeBytes: 512,
	};
}

export function addContent(
	contentByHandleId: Map<string, string>,
	item: BridgeReviewItemDescriptor,
	content: { readonly base?: string; readonly head?: string },
): void {
	const baseHandle = item.contentRoles.base ?? null;
	const headHandle = item.contentRoles.head ?? null;
	if (baseHandle !== null && content.base !== undefined) {
		contentByHandleId.set(baseHandle.handleId, content.base);
	}
	if (headHandle !== null && content.head !== undefined) {
		contentByHandleId.set(headHandle.handleId, content.head);
	}
}

export function reviewItemWithContentSizes(props: {
	readonly item: BridgeReviewItemDescriptor;
	readonly contentByHandleId: ReadonlyMap<string, string>;
}): BridgeReviewItemDescriptor {
	return {
		...props.item,
		contentRoles: {
			base: contentHandleWithMockedSize({
				handle: props.item.contentRoles.base,
				contentByHandleId: props.contentByHandleId,
			}),
			head: contentHandleWithMockedSize({
				handle: props.item.contentRoles.head,
				contentByHandleId: props.contentByHandleId,
			}),
			diff: contentHandleWithMockedSize({
				handle: props.item.contentRoles.diff,
				contentByHandleId: props.contentByHandleId,
			}),
			file: contentHandleWithMockedSize({
				handle: props.item.contentRoles.file,
				contentByHandleId: props.contentByHandleId,
			}),
		},
		contentLineCountsByRole: contentLineCountsByRoleWithMockedContent({
			item: props.item,
			contentByHandleId: props.contentByHandleId,
		}),
	};
}

export function contentLineCountsByRoleWithMockedContent(props: {
	readonly item: BridgeReviewItemDescriptor;
	readonly contentByHandleId: ReadonlyMap<string, string>;
}): BridgeReviewItemDescriptor['contentLineCountsByRole'] {
	const lineCountsByRole: NonNullable<BridgeReviewItemDescriptor['contentLineCountsByRole']> = {};
	for (const role of [
		'base',
		'head',
		'diff',
		'file',
	] as const satisfies readonly BridgeContentRole[]) {
		const handle = props.item.contentRoles[role] ?? null;
		if (handle === null) {
			continue;
		}
		const content = props.contentByHandleId.get(handle.handleId);
		if (content === undefined) {
			continue;
		}
		lineCountsByRole[role] = lineCount(content);
	}
	return Object.keys(lineCountsByRole).length === 0 ? undefined : lineCountsByRole;
}

export function contentHandleWithMockedSize(props: {
	readonly handle: BridgeContentHandle | null | undefined;
	readonly contentByHandleId: ReadonlyMap<string, string>;
}): BridgeContentHandle | null | undefined {
	if (props.handle === null || props.handle === undefined) {
		return props.handle;
	}
	const content = props.contentByHandleId.get(props.handle.handleId);
	if (content === undefined) {
		return props.handle;
	}
	return {
		...props.handle,
		sizeBytes: new TextEncoder().encode(content).byteLength,
	};
}

export function requiredHandleId(
	handle: BridgeContentHandle | null | undefined,
	label: string,
): string {
	if (handle === null || handle === undefined) {
		throw new Error(`expected ${label} content handle`);
	}
	return handle.handleId;
}

export function largeBrowserDiffText(label: 'base' | 'head'): string {
	return Array.from({ length: 50_000 }, (_value: unknown, index: number): string => {
		const paddedIndex = index.toString().padStart(4, '0');
		return `export const generatedLine${paddedIndex} = '${label}';`;
	}).join('\n');
}

export function hunkedBrowserDiffText(label: 'base' | 'head'): string {
	return Array.from({ length: 60 }, (_value: unknown, index: number): string => {
		const paddedIndex = index.toString().padStart(4, '0');
		if (index === 4 || index === 47) {
			return `export const changedContextLine${paddedIndex} = '${label}';`;
		}
		return `export const stableContextLine${paddedIndex} = 'same';`;
	}).join('\n');
}

export function countChangeKinds(
	items: readonly BridgeReviewItemDescriptor[],
): Readonly<Record<BridgeFileChangeKind, number>> {
	return {
		added: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.changeKind === 'added',
		),
		modified: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.changeKind === 'modified',
		),
		deleted: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.changeKind === 'deleted',
		),
		renamed: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.changeKind === 'renamed',
		),
		copied: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.changeKind === 'copied',
		),
	};
}

export function countFileClasses(
	items: readonly BridgeReviewItemDescriptor[],
): Readonly<Record<BridgeFileClass, number>> {
	return {
		source: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'source',
		),
		test: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'test',
		),
		docs: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'docs',
		),
		config: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'config',
		),
		generated: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'generated',
		),
		vendor: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'vendor',
		),
		binary: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'binary',
		),
		large: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'large',
		),
		fixture: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'fixture',
		),
		unknown: countItemsWhere(
			items,
			(item: BridgeReviewItemDescriptor): boolean => item.fileClass === 'unknown',
		),
	};
}

export function countItemsWhere(
	items: readonly BridgeReviewItemDescriptor[],
	predicate: (item: BridgeReviewItemDescriptor) => boolean,
): number {
	return items.filter(predicate).length;
}

export function selectedLargeContentLineCount(
	contentByHandleId: ReadonlyMap<string, string>,
	largeItem: BridgeReviewItemDescriptor,
): number {
	const baseHandle = largeItem.contentRoles.base ?? null;
	const headHandle = largeItem.contentRoles.head ?? null;
	const baseLineCount =
		baseHandle === null ? 0 : lineCount(contentByHandleId.get(baseHandle.handleId));
	const headLineCount =
		headHandle === null ? 0 : lineCount(contentByHandleId.get(headHandle.handleId));
	return baseLineCount + headLineCount;
}

export function lineCount(content: string | undefined): number {
	if (content === undefined || content.length === 0) {
		return 0;
	}
	return content.split('\n').length;
}
