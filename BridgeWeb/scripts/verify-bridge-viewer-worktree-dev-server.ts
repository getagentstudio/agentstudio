import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BridgeWebTestLaunch } from './dev-server/bridge-web-test-launch.ts';
import {
	bridgeCompleteJourneyMinimumAttemptsPerLaunch,
	reduceBridgeCompleteJourneyCohort,
	type BridgeCompleteJourney,
} from './verify-bridge-viewer-worktree-dev-server/complete-journey-cohort.ts';
import {
	bridgeCompleteJourneyLaunchForJourney,
	type BridgeDevelopmentCompleteJourneyLaunch,
} from './verify-bridge-viewer-worktree-dev-server/complete-journey-collector.ts';
import {
	completeJourneyAttemptCount,
	completeJourneyMode,
	execFileAsync,
	performanceOnlyMode,
	proofRunDirectoryPath,
	startupOnlyMode,
} from './verify-bridge-viewer-worktree-dev-server/config.ts';

const bridgePerformanceVerifierPaneId = '00000000-0000-7000-8000-000000000002';
const repoRootPath = fileURLToPath(new URL('../../', import.meta.url));
const bridgeCompleteJourneys = [
	'firstFile',
	'firstReview',
	'fileToReview',
	'reviewToFile',
] as const satisfies readonly BridgeCompleteJourney[];

type StartupSurface = 'file' | 'review';

interface ColdStartupSurfaceResult {
	readonly browserProof: unknown;
	readonly observedPageUrl: string;
	readonly proof: unknown;
	readonly satisfied: boolean;
	readonly scenarioName: string;
	readonly surface: StartupSurface;
}

type LoadVerifierRunner = (launch: BridgeWebTestLaunch) => Promise<unknown>;
export async function runBridgeViewerWorktreeVerifier(
	loadRunner: LoadVerifierRunner,
	ownerLaunch?: BridgeWebTestLaunch,
): Promise<void> {
	if (completeJourneyMode || performanceOnlyMode || startupOnlyMode) {
		await runSelfHostedBridgeViewerPerformanceVerifier(loadRunner, ownerLaunch);
	} else {
		await runSelfHostedBridgeViewerProductOnlyRegression();
	}
}

async function runSelfHostedBridgeViewerProductOnlyRegression(): Promise<void> {
	const regression =
		await import('./verify-bridge-viewer-worktree-dev-server/product-only-real-router-regression-runner.ts');
	await regression.runSelfHostedBridgeViewerProductOnlyRegression();
}

async function runSelfHostedBridgeViewerPerformanceVerifier(
	loadRunner: LoadVerifierRunner,
	ownerLaunch?: BridgeWebTestLaunch,
): Promise<void> {
	const previousBackendOrigin = process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
	const previousWorktreeDevServerUrl = process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];
	const launch =
		ownerLaunch === undefined
			? await BridgeWebTestLaunch.start({
					backend: {
						initialTarget: 'HEAD',
						paneId: bridgePerformanceVerifierPaneId,
						repoRootPath,
						worktreeRoot: repoRootPath,
					},
					dataRootPrefix: 'agentstudio-bridge-performance-',
				})
			: await ownerLaunch.startChild({
					initialTarget: 'HEAD',
					paneId: bridgePerformanceVerifierPaneId,
					repoRootPath,
					worktreeRoot: repoRootPath,
				});
	try {
		process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = launch.backend.origin;
		if (completeJourneyMode) {
			await runCompleteJourneyDevelopmentCohort(loadRunner, launch);
			return;
		}
		if (startupOnlyMode) {
			const file = await runColdStartupSurfaceLifecycle({ surface: 'file' }, loadRunner, launch);
			const review = await runColdStartupSurfaceLifecycle(
				{ surface: 'review' },
				loadRunner,
				launch,
			);
			console.log(
				JSON.stringify(
					{
						browserProof: { file: file.browserProof, review: review.browserProof },
						file: file.proof,
						observedPageUrls: { file: file.observedPageUrl, review: review.observedPageUrl },
						review: review.proof,
						scenarioName: file.scenarioName,
					},
					null,
					2,
				),
			);
			if (!file.satisfied || !review.satisfied) process.exitCode = 1;
			return;
		}
		const viteServer = await launch.startViteChild({
			bridgeWebRootPath: fileURLToPath(new URL('../', import.meta.url)),
			bridgeDevelopmentServerOrigin:
				process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] ?? launch.backend.origin,
		});
		process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] =
			`${viteServer.startProof.origin}/?fixture=worktree&viewer=file&workers=on&scenario=current-worktree`;
		await waitForBridgeProductBackendReady(viteServer.startProof.origin, launch);

		const loadedRunner: unknown = await loadRunner(launch);
		if (typeof loadedRunner !== 'object' || loadedRunner === null) {
			throw new Error('Expected the owned performance verifier runner module.');
		}
		const runVerifier = (loadedRunner as Readonly<Record<string, unknown>>)[
			'runBridgeViewerWorktreeDevServerVerifier'
		];
		if (typeof runVerifier !== 'function') {
			throw new Error('Expected the owned performance verifier runner entrypoint.');
		}
		await runVerifier(launch);
	} finally {
		try {
			await launch.dispose();
		} finally {
			restoreEnvironmentValue('BRIDGE_WEB_DEV_BACKEND_ORIGIN', previousBackendOrigin);
			restoreEnvironmentValue(
				'BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL',
				previousWorktreeDevServerUrl,
			);
		}
	}
}

async function runCompleteJourneyDevelopmentCohort(
	loadRunner: LoadVerifierRunner,
	parentLaunch: BridgeWebTestLaunch,
): Promise<void> {
	const sourceHeadResult = await execFileAsync('/usr/bin/git', ['rev-parse', 'HEAD'], {
		cwd: repoRootPath,
		encoding: 'utf8',
	});
	const sourceHead = sourceHeadResult.stdout.trim();
	const launches: BridgeDevelopmentCompleteJourneyLaunch[] = [];
	for (let launchIndex = 0; launchIndex < 3; launchIndex += 1) {
		// oxlint-disable-next-line no-await-in-loop -- Acceptance requires three independent Vite/browser launches.
		launches.push(
			await runCompleteJourneyLaunchLifecycle(
				{
					attemptCount: completeJourneyAttemptCount,
					launchIndex,
					sourceHead,
				},
				loadRunner,
				parentLaunch,
			),
		);
	}
	const diagnosticOnly =
		completeJourneyAttemptCount < bridgeCompleteJourneyMinimumAttemptsPerLaunch;
	const reductions = diagnosticOnly
		? null
		: bridgeCompleteJourneys.map((journey) =>
				reduceBridgeCompleteJourneyCohort({
					carrier: 'development',
					journey,
					launches: launches.map((launch) =>
						bridgeCompleteJourneyLaunchForJourney(launch, journey),
					),
				}),
			);
	const failureCount = launches.reduce(
		(count, launch) =>
			count +
			bridgeCompleteJourneys.reduce(
				(journeyCount, journey) =>
					journeyCount +
					launch.attemptsByJourney[journey].filter((attempt) => attempt.outcome === 'failed')
						.length,
				0,
			),
		0,
	);
	await mkdir(proofRunDirectoryPath, { recursive: true });
	const artifactPath = join(proofRunDirectoryPath, 'bridge-complete-journey-development.json');
	await writeFile(
		artifactPath,
		`${JSON.stringify({ diagnosticOnly, failureCount, launches, reductions }, null, 2)}\n`,
		'utf8',
	);
	console.log(
		JSON.stringify(
			{
				artifactPath,
				attemptCountPerJourneyPerLaunch: completeJourneyAttemptCount,
				diagnosticOnly,
				failureCount,
				reductions,
			},
			null,
			2,
		),
	);
	if (failureCount > 0 || reductions?.some((reduction) => !reduction.satisfied) === true) {
		process.exitCode = 1;
	}
}

async function runCompleteJourneyLaunchLifecycle(
	props: {
		readonly attemptCount: number;
		readonly launchIndex: number;
		readonly sourceHead: string;
	},
	loadRunner: LoadVerifierRunner,
	parentLaunch: BridgeWebTestLaunch,
): Promise<BridgeDevelopmentCompleteJourneyLaunch> {
	const previousWorktreeDevServerUrl = process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];
	const launch = await parentLaunch.startChildWithoutBackend();
	try {
		const viteServer = await launch.startViteChild({
			bridgeWebRootPath: fileURLToPath(new URL('../', import.meta.url)),
			bridgeDevelopmentServerOrigin:
				process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] ?? launch.backend.origin,
		});
		const viteOrigin = viteServer.startProof.origin;
		process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] =
			`${viteOrigin}/?fixture=worktree&viewer=file&workers=on&scenario=current-worktree`;
		await waitForBridgeProductBackendReady(viteOrigin, launch);
		const loadedRunner: unknown = await loadRunner(launch);
		if (typeof loadedRunner !== 'object' || loadedRunner === null) {
			throw new Error('Expected the complete-journey verifier runner module.');
		}
		const runLaunch = (loadedRunner as Readonly<Record<string, unknown>>)[
			'runBridgeViewerWorktreeDevServerCompleteJourneyLaunch'
		];
		if (typeof runLaunch !== 'function') {
			throw new Error('Expected the complete-journey launch entrypoint.');
		}
		return completeJourneyLaunchFromUnknown(
			await runLaunch({
				attemptCount: props.attemptCount,
				launchId: `development-launch-${props.launchIndex}`,
				sourceHead: props.sourceHead,
				launch,
			}),
		);
	} finally {
		try {
			await launch.dispose();
		} finally {
			restoreEnvironmentValue(
				'BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL',
				previousWorktreeDevServerUrl,
			);
		}
	}
}

function completeJourneyLaunchFromUnknown(value: unknown): BridgeDevelopmentCompleteJourneyLaunch {
	if (
		typeof value !== 'object' ||
		value === null ||
		!('launchId' in value) ||
		typeof value.launchId !== 'string' ||
		!('evidence' in value) ||
		typeof value.evidence !== 'object' ||
		value.evidence === null ||
		!('attemptsByJourney' in value) ||
		typeof value.attemptsByJourney !== 'object' ||
		value.attemptsByJourney === null
	) {
		throw new Error('Expected a complete-journey development launch result.');
	}
	return value as BridgeDevelopmentCompleteJourneyLaunch;
}

function restoreEnvironmentValue(name: string, previousValue: string | undefined): void {
	if (previousValue === undefined) {
		delete process.env[name];
	} else {
		process.env[name] = previousValue;
	}
}

async function runColdStartupSurfaceLifecycle(
	props: {
		readonly surface: StartupSurface;
	},
	loadRunner: LoadVerifierRunner,
	parentLaunch?: BridgeWebTestLaunch,
): Promise<ColdStartupSurfaceResult> {
	const previousWorktreeDevServerUrl = process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];
	const launch =
		parentLaunch === undefined
			? await BridgeWebTestLaunch.start()
			: await parentLaunch.startChildWithoutBackend();
	try {
		const viteServer = await launch.startViteChild({
			bridgeWebRootPath: fileURLToPath(new URL('../', import.meta.url)),
			bridgeDevelopmentServerOrigin:
				process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] ?? launch.backend.origin,
		});
		const viteOrigin = viteServer.startProof.origin;
		process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] =
			`${viteOrigin}/?fixture=worktree&viewer=${props.surface}&workers=on&scenario=current-worktree`;
		await waitForBridgeProductBackendReady(viteOrigin, launch);
		const loadedRunner: unknown = await loadRunner(launch);
		if (typeof loadedRunner !== 'object' || loadedRunner === null) {
			throw new Error('Expected the cold-start verifier runner module.');
		}
		const runSurfaceVerifier = (loadedRunner as Readonly<Record<string, unknown>>)[
			'runBridgeViewerWorktreeDevServerStartupSurfaceVerifier'
		];
		if (typeof runSurfaceVerifier !== 'function') {
			throw new Error('Expected the cold-start surface verifier entrypoint.');
		}
		return coldStartupSurfaceResultFromUnknown(
			await runSurfaceVerifier(props.surface, launch),
			props.surface,
		);
	} finally {
		try {
			await launch.dispose();
		} finally {
			restoreEnvironmentValue(
				'BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL',
				previousWorktreeDevServerUrl,
			);
		}
	}
}

function coldStartupSurfaceResultFromUnknown(
	value: unknown,
	expectedSurface: StartupSurface,
): ColdStartupSurfaceResult {
	if (
		typeof value !== 'object' ||
		value === null ||
		!('surface' in value) ||
		value.surface !== expectedSurface ||
		!('satisfied' in value) ||
		typeof value.satisfied !== 'boolean' ||
		!('proof' in value) ||
		typeof value.proof !== 'object' ||
		value.proof === null ||
		!('observedPageUrl' in value) ||
		typeof value.observedPageUrl !== 'string' ||
		!('scenarioName' in value) ||
		typeof value.scenarioName !== 'string' ||
		!('browserProof' in value)
	) {
		throw new Error(`Expected the ${expectedSurface} cold-start result.`);
	}
	return value as ColdStartupSurfaceResult;
}

async function waitForBridgeProductBackendReady(
	viteOrigin: string,
	launch: BridgeWebTestLaunch,
): Promise<void> {
	const response = await launch.runStep(
		'proxied backend health',
		async (signal) => await fetch(new URL('/__bridge-product/health', viteOrigin), { signal }),
	);
	if (response.status !== 204)
		throw new Error(`Owned Bridge development backend health failed: ${response.status}`);
}
