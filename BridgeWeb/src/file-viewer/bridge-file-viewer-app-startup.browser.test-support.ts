import { act } from 'react';

import { findBridgeViewerTreeItemButton } from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { waitForBridgeFileViewerBrowserDomState } from './bridge-file-viewer-browser-test-dom-state.js';
import {
	actFrame,
	bridgeFileViewerNoopResizeObserverIsInstalled,
} from './bridge-file-viewer-browser-test-harness.js';

interface FileViewerUiTraceEntry {
	readonly contentStateText: string | null;
	readonly hasLazyFrame: boolean;
	readonly hasShell: boolean;
	readonly initialSurfaceState: string | null;
	readonly metadataTreeRowCount: string | null;
	readonly timestampMilliseconds: number;
	readonly visibleText: string;
}

export interface FileFilterActDiagnostic {
	oldCheckedIndicator: Element | null;
	selectedOption: HTMLElement | null;
}

export function recordFileFilterActDiagnostic(
	diagnostic: FileFilterActDiagnostic | null,
	phase: string,
): void {
	if (diagnostic === null) return;

	const popup = document.querySelector('[data-testid="worktree-file-filter-menu-popover"]');
	const popupAnimations =
		popup instanceof HTMLElement ? popup.getAnimations({ subtree: true }) : [];
	const selectedIndicator = diagnostic.selectedOption?.querySelector('[data-checked]') ?? null;
	const activeElement = document.activeElement;
	const activeElementOwner =
		activeElement === null
			? 'none'
			: popup instanceof HTMLElement && popup.contains(activeElement)
				? 'popup'
				: activeElement.getAttribute('data-testid') === 'worktree-file-filter-menu'
					? 'trigger'
					: 'other';
	const animationPlayStateCounts = popupAnimations.reduce<Record<AnimationPlayState, number>>(
		(counts, animation) => {
			counts[animation.playState] += 1;
			return counts;
		},
		{ finished: 0, idle: 0, paused: 0, running: 0 },
	);

	console.info(
		'[file-filter-act-diagnostic]',
		JSON.stringify({
			activeElementOwner,
			animationCount: popupAnimations.length,
			animationPlayStateCounts,
			noOpResizeObserverInstalled: bridgeFileViewerNoopResizeObserverIsInstalled(),
			oldCheckedIndicatorConnected: diagnostic.oldCheckedIndicator?.isConnected ?? null,
			phase,
			popupConnected: popup?.isConnected ?? false,
			selectedIndicatorConnected: selectedIndicator?.isConnected ?? false,
		}),
	);
}

declare global {
	interface Window {
		bridgeFileViewerUiTrace?: FileViewerUiTraceEntry[];
	}
}

export function startFileViewerUiTrace(): () => void {
	window.bridgeFileViewerUiTrace = [];
	const recordSnapshot = (): void => {
		const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
		const contentState = document.querySelector('[data-testid="bridge-file-viewer-content-state"]');
		window.bridgeFileViewerUiTrace?.push({
			contentStateText: normalizedText(contentState?.textContent ?? null),
			hasLazyFrame:
				document.querySelector('[data-testid="bridge-file-viewer-lazy-loading-frame"]') !== null,
			hasShell: shell !== null,
			initialSurfaceState: shell?.getAttribute('data-worktree-initial-surface-state') ?? null,
			metadataTreeRowCount: shell?.getAttribute('data-worktree-metadata-tree-row-count') ?? null,
			timestampMilliseconds: performance.now(),
			visibleText: normalizedText(document.body.textContent ?? '') ?? '',
		});
	};
	recordSnapshot();
	const observer = new MutationObserver(recordSnapshot);
	observer.observe(document.body, {
		attributes: true,
		childList: true,
		characterData: true,
		subtree: true,
	});
	return (): void => {
		observer.disconnect();
		recordSnapshot();
	};
}

export async function waitForFileViewerTrace(
	predicate: (entries: readonly FileViewerUiTraceEntry[]) => boolean,
	attempt = 0,
): Promise<void> {
	if (predicate(fileViewerUiTraceEntries())) {
		return;
	}
	if (attempt >= 60) {
		throw new Error(
			`Expected FileView UI trace predicate to pass; entries=${JSON.stringify(
				fileViewerUiTraceEntries().slice(-5),
			)}`,
		);
	}
	await actFrame();
	await waitForFileViewerTrace(predicate, attempt + 1);
}

export function fileViewerUiTraceEntries(): readonly FileViewerUiTraceEntry[] {
	return window.bridgeFileViewerUiTrace ?? [];
}

function normalizedText(text: string | null): string | null {
	if (text === null) {
		return null;
	}
	return text.replace(/\s+/gu, ' ').trim();
}

export function fileViewerPendingCanvasIsVisible(visibleText: string): boolean {
	return (
		visibleText.includes('Select a file') ||
		visibleText.includes('Preparing code viewer') ||
		visibleText.includes('Code highlighting worker unavailable')
	);
}

export async function waitForFileViewerHTMLElement(props: {
	readonly selector: string;
}): Promise<HTMLElement> {
	const element = await waitForBridgeFileViewerBrowserDomState({
		readState: (): Element | null => document.querySelector(props.selector),
		isExpected: (candidate): boolean => candidate instanceof HTMLElement,
	});
	if (!(element instanceof HTMLElement))
		throw new Error(`Expected FileView element ${props.selector}.`);
	return element;
}

export async function waitForFileViewerTreeItemButtonInAct(props: {
	readonly path: string;
}): Promise<HTMLButtonElement> {
	const button = await waitForBridgeFileViewerBrowserDomState({
		readState: (): HTMLButtonElement | null => findBridgeViewerTreeItemButton(props.path),
		isExpected: (candidate): boolean => candidate !== null,
	});
	if (button === null) throw new Error(`Expected FileView tree item ${props.path}.`);
	return button;
}

export async function waitForFileViewerMenuOptionContaining(props: {
	readonly text: string;
}): Promise<HTMLElement> {
	const option = await waitForBridgeFileViewerBrowserDomState({
		readState: (): HTMLElement | undefined =>
			[...document.querySelectorAll('[data-testid="worktree-file-filter-menu-option"]')]
				.filter((candidate): candidate is HTMLElement => candidate instanceof HTMLElement)
				.find((candidate): boolean => candidate.textContent?.includes(props.text) ?? false),
		isExpected: (candidate): boolean => candidate !== undefined,
	});
	if (option === undefined) throw new Error(`Expected FileView menu option ${props.text}.`);
	return option;
}

export async function actInteractAndSettleFileViewerCheckedMenuOption(props: {
	readonly interaction: () => Promise<void>;
	readonly onDiagnosticPhase?: (phase: FileViewerCheckedMenuDiagnosticPhase) => void;
	readonly option: HTMLElement;
}): Promise<void> {
	props.onDiagnosticPhase?.('before-interaction-act');
	await act(props.interaction);
	props.onDiagnosticPhase?.('after-interaction-act');
	await settleBaseUiTransitionMachine(props.onDiagnosticPhase);

	const checkedIndicator = props.option.querySelector(
		'[data-slot="dropdown-menu-checkbox-item-indicator"] [data-checked]',
	);
	if (!(checkedIndicator instanceof HTMLElement)) {
		throw new Error(
			'Expected FileView checkbox option transition to finish with a mounted data-checked indicator.',
		);
	}
	if (
		props.option.getAttribute('aria-checked') !== 'true' ||
		checkedIndicator.hasAttribute('data-starting-style') ||
		checkedIndicator.hasAttribute('data-ending-style')
	) {
		throw new Error(
			'Expected FileView checkbox option transition to finish with aria-checked=true and no transition style.',
		);
	}
}

export type FileViewerCheckedMenuDiagnosticPhase =
	| 'before-interaction-act'
	| 'after-interaction-act'
	| 'before-transition-frame-1'
	| 'after-transition-frame-1'
	| 'after-transition-frame-2';

export async function actClickAndSettleFileViewerMenu(element: HTMLElement): Promise<void> {
	const expectedExpandedState = element.getAttribute('aria-expanded') === 'true' ? 'false' : 'true';
	await act(async (): Promise<void> => {
		element.click();
	});
	await commitFileViewerMenuTransition();
	await act(async (): Promise<void> => {
		const popup = document.querySelector('[data-slot="dropdown-menu-content"]');
		if (popup instanceof HTMLElement) {
			await Promise.all(
				popup.getAnimations({ subtree: true }).map(async (animation): Promise<void> => {
					try {
						await animation.finished;
					} catch {
						/* Reversing a transition cancels its predecessor. */
					}
				}),
			);
		}
		await waitForFileViewerMenuState({ element, expectedExpandedState });
	});
}

async function commitFileViewerMenuTransition(): Promise<void> {
	// Base UI's starting-state cleanup and queued menu focus run on their registered frame.
	// Commit that state in its own act turn before waiting for animation/DOM completion.
	await act(async (): Promise<void> => {
		await new Promise<void>((resolve): void => {
			requestAnimationFrame((): void => resolve());
		});
	});
}

async function settleBaseUiTransitionMachine(
	onDiagnosticPhase?: (phase: FileViewerCheckedMenuDiagnosticPhase) => void,
): Promise<void> {
	// Base UI schedules transitionStatus='starting' cleanup on an animation frame. Its
	// animation-complete hook starts on another frame and can synchronously unmount an
	// ending indicator. Each frame gets its own act boundary so React commits the first
	// transition before Base UI schedules work from the next state.
	onDiagnosticPhase?.('before-transition-frame-1');
	await actFrame();
	onDiagnosticPhase?.('after-transition-frame-1');
	await actFrame();
	onDiagnosticPhase?.('after-transition-frame-2');
}

async function waitForFileViewerMenuState(props: {
	readonly element: HTMLElement;
	readonly expectedExpandedState: 'false' | 'true';
}): Promise<void> {
	await waitForBridgeFileViewerBrowserDomState({
		readState: (): boolean => {
			const popup = document.querySelector('[data-slot="dropdown-menu-content"]');
			const popupMatches =
				props.expectedExpandedState === 'true'
					? popup instanceof HTMLElement &&
						popup.hasAttribute('data-open') &&
						!popup.hasAttribute('data-starting-style') &&
						!popup.hasAttribute('data-ending-style')
					: popup === null;
			return (
				props.element.getAttribute('aria-expanded') === props.expectedExpandedState && popupMatches
			);
		},
		isExpected: (settled): boolean => settled,
	});
}
