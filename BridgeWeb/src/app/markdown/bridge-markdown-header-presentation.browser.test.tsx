import { act, cloneElement, type ReactElement } from 'react';
import { afterEach, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

import { createWorktreeAnnotationBrowserProviderHarness } from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import { useWorktreeAnnotationEditorInstallationPreparation } from '../../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	BridgeRegionUpdatingIndicator,
	type BridgeRegionPresentationRenderSlot,
} from '../bridge-region-presentation.js';
import { BridgeViewerContentHeader } from '../bridge-viewer-content-header.js';
import {
	BridgeViewerContextPanelProvider,
	BridgeViewerContextPanelViewport,
} from '../bridge-viewer-context-panel-host.js';
import { markdownCanvas } from './bridge-markdown-annotation-test-support.js';

// oxlint-disable-next-line import/no-unassigned-import -- Prove the real shared header and document geometry.
import '../bridge-app.css';

afterEach(async (): Promise<void> => {
	await act(async (): Promise<void> => {
		await cleanup();
	});
});

test('composes the held document and local Apply failure into one existing header indicator', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	let permitsInstallation = false;
	const prepare = async (): Promise<boolean> => permitsInstallation;
	const renderRegion: BridgeRegionPresentationRenderSlot = ({
		body,
		state,
		held,
	}): ReactElement => (
		<section className="grid h-full min-h-0 grid-rows-[auto_minmax(0,1fr)]">
			<BridgeViewerContentHeader
				mode="file"
				title="plan.md"
				statusText={null}
				regionIndicator={<BridgeRegionUpdatingIndicator state={state} held={held} />}
			/>
			<BridgeViewerContextPanelViewport testId="markdown-header-proof-viewport">
				{body}
			</BridgeViewerContextPanelViewport>
		</section>
	);
	const candidate = async (contents: string, version: number): Promise<ReactElement> =>
		harness.wrap(
			<BridgeViewerContextPanelProvider>
				<div style={{ height: 500, width: '100%' }}>
					<EditorPreparation prepare={prepare} />
					{cloneElement(await markdownCanvas(contents, version), { renderRegion })}
				</div>
			</BridgeViewerContextPanelProvider>,
		);
	const rendered = await render(await candidate('Last good document', 1));
	const articleTop = rendered
		.getByTestId('bridge-markdown-canvas')
		.element()
		.getBoundingClientRect().top;
	const header = rendered.getByTestId('bridge-viewer-content-topbar').element();
	const headerHeight = header.getBoundingClientRect().height;
	const viewport = rendered.getByTestId('markdown-header-proof-viewport').element();
	expect(header.getBoundingClientRect().left).toBe(viewport.getBoundingClientRect().left);
	expect(header.getBoundingClientRect().right).toBe(viewport.getBoundingClientRect().right);
	await rendered.rerender(await candidate('Latest document', 2));
	await expect.element(rendered.getByRole('status', { name: 'File changed' })).toBeVisible();
	expect(header.contains(rendered.getByRole('status').element())).toBe(true);
	expect(rendered.container.querySelectorAll('[role="status"]')).toHaveLength(1);
	expect(
		rendered.container.querySelector('[data-bridge-region="markdown"] [role="status"]'),
	).toBeNull();
	expect(rendered.getByTestId('bridge-markdown-canvas').element().getBoundingClientRect().top).toBe(
		articleTop,
	);
	expect(header.getBoundingClientRect().height).toBe(headerHeight);
	expect(header.getBoundingClientRect().right).toBe(viewport.getBoundingClientRect().right);
	await act(async (): Promise<void> => {
		await rendered.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect
		.element(rendered.getByRole('status', { name: "Couldn't apply update" }))
		.toBeVisible();
	expect(
		rendered.container
			.querySelector('[data-bridge-region="markdown"]')
			?.getAttribute('data-presentation-state'),
	).toBe('updating');
	await expect.element(rendered.getByText('Last good document', { exact: true })).toBeVisible();
	expect(rendered.container.querySelectorAll('[role="status"]')).toHaveLength(1);
	await page.screenshot({
		path: '../../../../tmp/g1-markdown-held-header.png',
	});
	permitsInstallation = true;
	await act(async (): Promise<void> => {
		await rendered.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect.element(rendered.getByText('Latest document', { exact: true })).toBeVisible();
	expect(rendered.container.querySelector('[role="status"]')).toBeNull();
});

function EditorPreparation(props: { readonly prepare: () => Promise<boolean> }): null {
	useWorktreeAnnotationEditorInstallationPreparation('header-apply-preparation', props.prepare);
	return null;
}
