/* oxlint-disable unicorn/consistent-function-scoping -- Playwright page callbacks must carry their own DOM helpers. */

import type { Page } from 'playwright';

import { BridgeWebTestLaunch } from './dev-server/bridge-web-test-launch.ts';
import { createBridgeViewerDevServerPageHarness } from './verify-bridge-viewer-dev-server/page-harness.ts';
import type {
	BridgeViewerBrowserFixtureClass,
	DevServerVerificationResult,
	DirectMarkdownSelectionState,
	FixtureTargets,
} from './verify-bridge-viewer-dev-server/types.ts';

const defaultDevServerUrl =
	'http://127.0.0.1:5173/?fixture=large-diffshub&workers=on&scenario=scroll';
const devServerUrl = process.env['BRIDGE_VIEWER_DEV_SERVER_URL'] ?? defaultDevServerUrl;
const fixtureClass = fixtureClassFromDevServerUrl(devServerUrl);
const fixtureTargets = fixtureTargetsForFixtureClass(fixtureClass);
const targetAddedPath = fixtureTargets.addedPath;
const targetAddedText = fixtureTargets.addedText;
const targetMarkdownPath = fixtureTargets.docsPath;
const targetMarkdownHeading = fixtureTargets.docsMarkdownHeading;
const targetModifiedPath = fixtureTargets.initialPath;
const targetModifiedText = fixtureTargets.initialText;

const {
	assertCodeViewScrolledToSelectedItem,
	assertGitStatusFilterMenu,
	assertNoEmptyExpandedHeaders,
	assertSelectedHeaderCollapseButton,
	assertSelectedHeaderCollapseRoundTrip,
	assertSelectedScrollMotion,
	assertTopScopeStateRemoved,
	clickFileTreePathAndMeasureScrollMotion,
	fillBridgeViewerFileTreeSearch,
	inspectGitStatusFilterMenu,
	readVerificationResult,
	searchForAddedFile,
	searchTextForPath,
	selectFileAndWaitForContent,
	verifyFilterBehavior,
	waitForCodeViewText,
	waitForFileTreePath,
	waitForSelectedHeaderAligned,
	waitForSelectedPath,
	waitForReviewViewerReady,
} = createBridgeViewerDevServerPageHarness({
	targetAddedPath,
	targetAddedText,
	targetMarkdownPath,
});

const markdownDevServerUrl = devServerUrlWithScenario(devServerUrl, 'markdown');

const browser = await BridgeWebTestLaunch.startBrowser({ headless: true });

try {
	const directMarkdownSelection = await verifyDirectMarkdownInitialSelection();
	const result = await verifyScrollScenario();
	const markdownResult = await verifyMarkdownScenario();

	console.log(
		JSON.stringify(
			{
				ok: true,
				devServerUrl,
				codeViewScrollHeight: result.codeViewScrollHeight,
				codeViewScrollTop: result.codeViewScrollTop,
				directMarkdownSelection,
				filterBehavior: result.filterBehaviorState,
				fixtureClass,
				gitStatusFilterMenu: result.gitStatusFilterMenuState,
				hydrationDiagnostics: result.hydrationDiagnostics,
				markdownSelectionScrollMotion: result.markdownSelectionScrollMotion,
				selectedScrollMotion: result.selectedScrollMotion,
				selectedHeaderCollapseButton: result.selectedHeaderCollapseButtonState,
				markdownDevServerUrl,
				markdownDisplayPath: markdownResult.displayPath,
				selectedDisplayPath: result.selectedDisplayPath,
				topScope: result.topScopeState,
				workerPoolState: result.workerPoolState,
			},
			null,
			2,
		),
	);
} finally {
	await browser.close();
}

async function verifyDirectMarkdownInitialSelection(): Promise<DirectMarkdownSelectionState> {
	const page = await makeVerificationPage();
	try {
		await page.goto(devServerUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
		await waitForReviewViewerReady(page);
		const initialResult = await readVerificationResult(page);
		const scrollMotion = await clickFileTreePathAndMeasureScrollMotion(page, targetMarkdownPath);
		await waitForSelectedPath(page, targetMarkdownPath);
		await waitForCodeViewText(page, targetMarkdownHeading);
		await waitForSelectedHeaderAligned(page);
		const selectedResult = {
			...(await readVerificationResult(page)),
			markdownSelectionScrollMotion: scrollMotion,
		};
		assertSelectedHeaderCollapseButton(selectedResult);
		assertSelectedScrollMotion(selectedResult.markdownSelectionScrollMotion);
		if (!selectedResult.codeViewVisibleText.includes(targetMarkdownHeading)) {
			throw new Error(
				[
					'Expected direct markdown selection to make the markdown source visible.',
					`Missing text: ${targetMarkdownHeading}`,
					`Visible text: ${selectedResult.codeViewVisibleText.slice(0, 500)}`,
				].join('\n'),
			);
		}
		return {
			initialScrollTop: initialResult.codeViewScrollTop,
			selectedDisplayPath: selectedResult.selectedDisplayPath,
			selectedHeaderCollapseButtonState: selectedResult.selectedHeaderCollapseButtonState,
			selectedScrollTop: selectedResult.codeViewScrollTop,
			scrollMotion,
		};
	} finally {
		await page.close();
	}
}

async function verifyScrollScenario(): Promise<DevServerVerificationResult> {
	const page = await makeVerificationPage();
	try {
		await page.goto(devServerUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
		await waitForReviewViewerReady(page);
		const initialResult = await readVerificationResult(page);
		assertTopScopeStateRemoved(initialResult.topScopeState);
		const gitStatusFilterMenuState = await inspectGitStatusFilterMenu(page);
		assertGitStatusFilterMenu(gitStatusFilterMenuState);
		const filterBehaviorState = await verifyFilterBehavior(page, initialResult);
		await selectFileAndWaitForContent({
			page,
			path: targetModifiedPath,
			searchText: searchTextForPath(targetModifiedPath),
			text: targetModifiedText,
		});
		await searchForAddedFile(page);
		const selectedScrollMotion = await clickFileTreePathAndMeasureScrollMotion(
			page,
			targetAddedPath,
		);
		await waitForSelectedPath(page, targetAddedPath);
		await waitForCodeViewText(page, targetAddedText);
		await waitForSelectedHeaderAligned(page);

		const addedResult = {
			...(await readVerificationResult(page)),
			filterBehaviorState,
			gitStatusFilterMenuState,
			markdownSelectionScrollMotion: null,
			selectedScrollMotion,
		};
		assertSelectedHeaderCollapseButton(addedResult);
		assertSelectedScrollMotion(addedResult.selectedScrollMotion);
		if (addedResult.selectedDisplayPath !== targetAddedPath) {
			throw new Error(
				`Expected selected display path ${targetAddedPath}, got ${
					addedResult.selectedDisplayPath ?? 'null'
				}`,
			);
		}
		if (addedResult.selectedContentState !== 'ready') {
			throw new Error(
				`Expected selected content state ready, got ${addedResult.selectedContentState ?? 'null'}`,
			);
		}
		if (addedResult.workerPoolState !== 'ready') {
			throw new Error(
				`Expected worker pool state ready, got ${addedResult.workerPoolState ?? 'null'}`,
			);
		}
		if (!addedResult.codeViewVisibleText.includes(targetAddedText)) {
			throw new Error(
				[
					'Expected added file content to be visible in the CodeView scroll owner.',
					`Missing text: ${targetAddedText}`,
					`Visible text: ${addedResult.codeViewVisibleText.slice(0, 500)}`,
				].join('\n'),
			);
		}
		assertNoEmptyExpandedHeaders(addedResult.hydrationDiagnostics, 'selected added file');
		assertCodeViewScrolledToSelectedItem({ initialResult, result: addedResult });
		await assertSelectedHeaderCollapseRoundTrip(page);

		await fillBridgeViewerFileTreeSearch(page, searchTextForPath(targetMarkdownPath));
		await waitForFileTreePath(page, targetMarkdownPath);
		const markdownSelectionScrollMotion = await clickFileTreePathAndMeasureScrollMotion(
			page,
			targetMarkdownPath,
		);
		await waitForSelectedPath(page, targetMarkdownPath);
		await waitForSelectedHeaderAligned(page);
		const result = {
			...(await readVerificationResult(page)),
			filterBehaviorState,
			gitStatusFilterMenuState,
			markdownSelectionScrollMotion,
			selectedScrollMotion,
		};
		assertSelectedHeaderCollapseButton(result);
		assertSelectedScrollMotion(result.markdownSelectionScrollMotion);
		if (result.selectedDisplayPath !== targetMarkdownPath) {
			throw new Error(
				`Expected selected display path ${targetMarkdownPath}, got ${
					result.selectedDisplayPath ?? 'null'
				}`,
			);
		}
		if (result.selectedContentState !== 'ready') {
			throw new Error(
				`Expected selected content state ready, got ${result.selectedContentState ?? 'null'}`,
			);
		}
		if (result.workerPoolState !== 'ready') {
			throw new Error(`Expected worker pool state ready, got ${result.workerPoolState ?? 'null'}`);
		}
		if (!result.codeViewVisibleText.includes(targetMarkdownHeading)) {
			throw new Error(
				[
					'Expected selected markdown source to be visible in the CodeView scroll owner before preview command.',
					`Missing text: ${targetMarkdownHeading}`,
					`Visible text: ${result.codeViewVisibleText.slice(0, 500)}`,
				].join('\n'),
			);
		}
		assertNoEmptyExpandedHeaders(result.hydrationDiagnostics, 'selected markdown file');
		assertCodeViewScrolledToSelectedItem({ initialResult, result });
		return result;
	} finally {
		await page.close();
	}
}

interface MarkdownScenarioResult {
	readonly displayPath: string | null;
}

async function verifyMarkdownScenario(): Promise<MarkdownScenarioResult> {
	const page = await makeVerificationPage();
	try {
		await page.goto(markdownDevServerUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
		await waitForSelectedPath(page, targetMarkdownPath);
		await page.locator('[data-testid="bridge-viewer-context-file"]').click();
		await page.waitForSelector(
			'[data-bridge-viewer-mode-active="true"] [data-testid="bridge-file-viewer-shell"]',
		);
		await page.waitForSelector('[data-testid="bridge-markdown-canvas"] h1');
		await page.waitForSelector('[data-bridge-mermaid-state="ready"] svg');
		await page.waitForSelector(
			'[data-testid="bridge-markdown-canvas"] pre code span[style*="color"]',
		);
		const result = await page.evaluate((): MarkdownScenarioResult => {
			const markdownCanvas = document.querySelector('[data-testid="bridge-markdown-canvas"]');
			return {
				displayPath: markdownCanvas?.getAttribute('data-bridge-markdown-source-path') ?? null,
			};
		});
		if (result.displayPath !== targetMarkdownPath) {
			throw new Error(
				`Expected markdown preview source ${targetMarkdownPath}, got ${
					result.displayPath ?? 'null'
				}`,
			);
		}
		return result;
	} finally {
		await page.close();
	}
}

async function makeVerificationPage(): Promise<Page> {
	return await browser.newPage({
		deviceScaleFactor: 1,
		viewport: {
			width: 1728,
			height: 980,
		},
	});
}

function fixtureClassFromDevServerUrl(url: string): BridgeViewerBrowserFixtureClass {
	const parsedUrl = new URL(url);
	const fixtureParameter = parsedUrl.searchParams.get('fixture') ?? 'large-diffshub';
	switch (fixtureParameter) {
		case 'small-mixed':
		case 'medium-agentstudio':
		case 'large-diffshub':
			return fixtureParameter;
		case 'off':
			throw new Error('Bridge viewer dev-server verifier requires a mocked fixture, got off');
		default:
			throw new Error(`Unsupported Bridge viewer fixture: ${fixtureParameter}`);
	}
}

function fixtureTargetsForFixtureClass(
	fixtureClassValue: BridgeViewerBrowserFixtureClass,
): FixtureTargets {
	switch (fixtureClassValue) {
		case 'small-mixed':
		case 'medium-agentstudio':
		case 'large-diffshub':
			return {
				addedPath: 'Sources/BridgeViewer/NewPanel.ts',
				addedText: "return 'full added file content';",
				docsMarkdownHeading: 'Browser fixture',
				docsPath: 'docs/plans/bridge-viewer-browser.md',
				initialPath: 'Sources/BridgeViewer/Alpha.ts',
				initialText: "export const selectedFile = 'alpha head visible';",
			};
	}
	const exhaustiveFixtureClass: never = fixtureClassValue;
	void exhaustiveFixtureClass;
	throw new Error('Unhandled Bridge viewer fixture class');
}

function devServerUrlWithScenario(url: string, scenario: string): string {
	const parsedUrl = new URL(url);
	parsedUrl.searchParams.set('scenario', scenario);
	return parsedUrl.toString();
}
