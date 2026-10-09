import { describe, expect, it } from 'vitest';

import { bridgeFileViewerContentHeaderTitle } from './bridge-file-viewer-content-header-title.js';

describe('bridgeFileViewerContentHeaderTitle', () => {
	it('shows only user-facing file context and never the transport source id', () => {
		const title = bridgeFileViewerContentHeaderTitle({
			selectedPath: '.gitignore',
			sourceId: 'pane-companion-uuid-worktree-uuid-1',
		});

		expect(title).toBe('.gitignore');
		expect(title).not.toContain('pane-companion-uuid');
		expect(title).not.toContain('worktree-uuid');
	});

	it('uses a neutral pending title before a file is selected', () => {
		expect(
			bridgeFileViewerContentHeaderTitle({
				selectedPath: null,
				sourceId: 'pane-companion-uuid-worktree-uuid-1',
			}),
		).toBe('Files');
	});
});
