import { useEffect, useMemo, useRef, type ReactElement } from 'react';

import { createBridgePaneRuntime } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductFileContentDescriptor } from '../core/comm-worker/bridge-product-content-contracts.js';
import type { BridgeProductSubscriptionOptions } from '../core/comm-worker/bridge-product-subscription-contracts.js';
import type { BridgeProductCallResult } from '../core/comm-worker/bridge-product-transport-contract.js';
import type { BridgeProductViewInstallation } from '../core/comm-worker/bridge-product-view-batch-receiver.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { WorktreeAnnotationSurfaceProvider } from '../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	BridgeFileViewerAppImplementation,
	type BridgeFileViewerAppProps,
} from './bridge-file-viewer-app.js';
import type {
	BrowserFileViewScope,
	PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	type BridgeFileViewerBrowserTestPaneSessionFactory,
} from './bridge-file-viewer-browser-test-harness.js';
import { BridgeFileViewerSurfaceClientProvider } from './bridge-file-viewer-render-snapshot-controller.js';
import { BridgeFileViewerShell } from './bridge-file-viewer-shell.js';

export interface BridgeFileViewerBrowserHarnessAppProps extends BridgeFileViewerAppProps {
	readonly fileProductSession?: BridgeFileViewerBrowserTestProductSession;
	readonly fileViewPaneSessionFactory?: BridgeFileViewerBrowserTestPaneSessionFactory;
	readonly initialFileBatch?: BridgeProductViewInstallation;
}

export interface BridgeFileViewerBrowserTestProductSession {
	readonly currentSource?: () =>
		| BridgeProductCallResult<'file.source.current'>
		| Promise<BridgeProductCallResult<'file.source.current'>>;
	readonly initialFileBatch?: BridgeProductViewInstallation;
	readonly onFileBatchPublisher?: (publisher: PublishBrowserFileBatch) => void | (() => void);
	readonly onMetadataSubscriptionOpen?: (
		options: BridgeProductSubscriptionOptions<'file.metadata'>,
	) => void;
	readonly onFileScopeChange?: (scope: BrowserFileViewScope) => void | Promise<void>;
	readonly onWorkerCommand?: (message: BridgeWorkerMainToServerMessage) => void;
	readonly onWorkerMessagesPublisher?: (
		publisher: (messages: readonly BridgeWorkerServerToMainMessage[]) => void,
	) => void;
	readonly readContent?: (props: {
		readonly descriptor: BridgeProductFileContentDescriptor;
		readonly signal: AbortSignal;
	}) => string | Promise<string>;
}

export function BridgeFileViewerBrowserHarnessApp(
	props: BridgeFileViewerBrowserHarnessAppProps = {},
): ReactElement {
	const productSessionRef = useRef<BridgeFileViewerBrowserTestProductSession | undefined>(
		undefined,
	);
	productSessionRef.current =
		props.fileProductSession === undefined && props.initialFileBatch === undefined
			? undefined
			: {
					...props.fileProductSession,
					...(props.initialFileBatch === undefined
						? {}
						: { initialFileBatch: props.initialFileBatch }),
				};
	const fileViewPaneSessionFactory = useMemo(
		() =>
			props.fileViewPaneSessionFactory ??
			createBridgeFileViewerBrowserTestPaneSessionFactory({ productSessionRef }),
		[props.fileViewPaneSessionFactory],
	);
	const paneRuntime = useMemo(
		() =>
			createBridgePaneRuntime({
				renderStoreFactory: fileViewPaneSessionFactory.renderStoreFactory,
				sessionFactory: fileViewPaneSessionFactory,
			}),
		[fileViewPaneSessionFactory],
	);
	useEffect((): (() => void) => (): void => paneRuntime.dispose(), [paneRuntime]);
	const {
		fileProductSession: _fileProductSession,
		fileViewPaneSessionFactory: _fileViewPaneSessionFactory,
		initialFileBatch: _initialFileBatch,
		...productionProps
	} = props;
	const fileViewClient = paneRuntime.surfaceClient('fileView');
	return (
		<BridgeFileViewerSurfaceClientProvider surfaceClient={fileViewClient}>
			<WorktreeAnnotationSurfaceProvider
				markdownWorkerClient={productionProps.markdownWorkerClient}
				surfaceClient={fileViewClient}
			>
				<BridgeFileViewerAppImplementation
					{...productionProps}
					codeViewWorkerPoolEnabled={productionProps.codeViewWorkerPoolEnabled ?? false}
					shellComponent={BridgeFileViewerShell}
				/>
			</WorktreeAnnotationSurfaceProvider>
		</BridgeFileViewerSurfaceClientProvider>
	);
}
