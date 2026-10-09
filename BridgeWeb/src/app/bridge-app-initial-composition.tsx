import { useEffect, useRef, type ReactElement } from 'react';

import { BridgePageConfigurationReadError } from '../bridge/bridge-page-configuration.js';
import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeAppProps } from './bridge-app.js';
import { readNativeBridgePaneReloadPort } from './bridge-native-pane-reload-port.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import { BridgeViewerAppShell } from './bridge-viewer-app-shell.js';

type BridgeInitialRuntimeComposition = (
	| { readonly kind: 'ready'; readonly runtime: BridgePaneRuntime; readonly ownsRuntime: boolean }
	| { readonly kind: 'configurationFailed' }
) & { readonly paneReloadPort: BridgePaneReloadPort | undefined };

function prepareInitialRuntime(props: BridgeAppProps): BridgeInitialRuntimeComposition {
	const paneReloadPort = props.paneReloadPort ?? readNativeBridgePaneReloadPort(props.target);
	try {
		return {
			kind: 'ready',
			paneReloadPort,
			runtime: props.paneRuntime ?? (props.paneRuntimeFactory ?? createBridgePaneRuntime)(),
			ownsRuntime: props.paneRuntime === undefined,
		};
	} catch (error: unknown) {
		if (error instanceof BridgePageConfigurationReadError)
			return { kind: 'configurationFailed', paneReloadPort };
		throw error;
	}
}

/** Admit configured runtime construction before mounting the ready app; other errors propagate. */
export function BridgeAppInitialComposition(
	props: BridgeAppProps & {
		readonly readyContent: (
			props: BridgeAppProps & { readonly paneRuntime: BridgePaneRuntime },
		) => ReactElement;
	},
): ReactElement {
	const compositionRef = useRef<BridgeInitialRuntimeComposition | null>(null);
	compositionRef.current ??= prepareInitialRuntime(props);
	const composition = compositionRef.current;
	useEffect(
		(): (() => void) => (): void => {
			if (composition.kind === 'ready' && composition.ownsRuntime) composition.runtime.dispose();
		},
		[composition],
	);
	if (composition.kind === 'configurationFailed') {
		return (
			<BridgeViewerAppShell
				appOwner="BridgeApp"
				mode={props.viewerMode ?? 'review'}
				paneFailedStart={{ kind: 'failedStart', cause: 'configurationUnavailable' }}
				{...(composition.paneReloadPort === undefined
					? {}
					: { paneReloadPort: composition.paneReloadPort })}
			>
				{null}
			</BridgeViewerAppShell>
		);
	}
	const ReadyContent = props.readyContent;
	return (
		<ReadyContent
			{...props}
			paneRuntime={composition.runtime}
			{...(composition.paneReloadPort === undefined
				? {}
				: { paneReloadPort: composition.paneReloadPort })}
		/>
	);
}
