import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';

export type FileNavigationCommand = Extract<
	BridgeProductNavigationCommand,
	{ readonly commandKind: 'activateTarget'; readonly surface: 'file' }
>;

export function makeFileContent(content: string): string {
	return content;
}

export async function fileContentSha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
	const digest = new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256', bytes));
	return Array.from(digest, (byte): string => byte.toString(16).padStart(2, '0')).join('');
}

export function logicalFileContentLineCount(bytes: Uint8Array): number {
	if (bytes.byteLength === 0) return 0;
	return countFileContentByte(bytes, 0x0a) + (bytes.at(-1) === 0x0a ? 0 : 1);
}

export function countFileContentByte(bytes: Uint8Array, expectedByte: number): number {
	let count = 0;
	for (const byte of bytes) {
		if (byte === expectedByte) count += 1;
	}
	return count;
}

export function fileNavigationCommandForPath(path: string): FileNavigationCommand {
	return {
		bindingRevision: 1,
		commandId: `test:file:${path}`,
		commandKind: 'activateTarget',
		source: {
			sourceId: 'dev-worktree-source',
			sourceKind: 'file',
			subscriptionGeneration: 1,
		},
		surface: 'file',
		target: { path, targetKind: 'file', version: 'current' },
	};
}
