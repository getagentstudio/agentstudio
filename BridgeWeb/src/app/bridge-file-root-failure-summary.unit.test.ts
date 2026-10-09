import { expect, test, vi } from 'vitest';

import {
	bridgeFileSurfacePresentationStatus,
	bridgeFileTreePresentation,
} from '../file-viewer/bridge-file-region-presentation.js';
import type { BridgeFileViewerDisplayModel } from '../file-viewer/bridge-file-viewer-display-model.js';
import { projectBridgePaneFailureSummary } from './bridge-pane-failure-summary.js';

const emptyFileDisplay: BridgeFileViewerDisplayModel = {
	acceptedQueryKey: null,
	fileItemById: { size: 0, get: () => undefined },
	projectedRowCount: 0,
	searchError: null,
	source: null,
	status: null,
	treeRowByPath: { get: () => undefined },
	totalRowCount: 0,
	firstFileRow: null,
};

test.each(['missingRoot', 'unreadableRoot'] as const)(
	'%s stays typed through W6, and several failed parts keep one generic sentence',
	(failureKind): void => {
		const surface = bridgeFileSurfacePresentationStatus({
			displayModel: emptyFileDisplay,
			panelChrome: { fileRefreshFailure: { failureKind, retryable: true } },
			recoveryFailed: false,
			isActive: true,
		});
		const fileState = bridgeFileTreePresentation({ displayModel: emptyFileDisplay, surface });
		const retryFile = vi.fn();
		const retryComments = vi.fn();
		const summary = projectBridgePaneFailureSummary([
			{ part: 'file', state: fileState, retry: retryFile },
			{ part: 'file', state: fileState, retry: retryFile },
			{
				part: 'comments',
				state: {
					kind: 'failed',
					retainsContent: false,
					failure: { kind: 'retryable', scope: 'surface', message: 'Comments failed' },
				},
				retry: retryComments,
			},
		]);
		expect(summary?.state.failure.message).toBe("Files and comments couldn't update.");
		summary?.retry?.();
		expect(retryFile).toHaveBeenCalledOnce();
		expect(retryComments).toHaveBeenCalledOnce();
	},
);

test.each(['missingRoot', 'unreadableRoot'] as const)(
	'%s names the root cause even when both File regions retain content',
	(failureKind): void => {
		const surface = bridgeFileSurfacePresentationStatus({
			displayModel: emptyFileDisplay,
			panelChrome: { fileRefreshFailure: { failureKind, retryable: true } },
			recoveryFailed: false,
			isActive: true,
		});
		if (surface.kind !== 'failed') throw new Error('Expected the typed File surface failure.');
		const state = { kind: 'failed', retainsContent: true, failure: surface.failure } as const;
		const summary = projectBridgePaneFailureSummary([
			{ part: 'file', state },
			{ part: 'file', state },
			{
				part: 'file',
				fileName: 'Selected.swift',
				state: {
					kind: 'failed',
					retainsContent: false,
					failure: { kind: 'retryable', scope: 'read', message: 'Selected file read failed' },
				},
			},
		]);
		expect(summary?.state.failure.message).toBe(
			failureKind === 'missingRoot'
				? "Files couldn't load. The worktree folder is missing."
				: "Files couldn't load. The worktree folder can't be read.",
		);
	},
);
