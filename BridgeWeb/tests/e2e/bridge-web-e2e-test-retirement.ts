import type { TestContext } from 'vitest';

import { runWithBridgeWebLaunchScope } from '../../scripts/dev-server/bridge-web-test-launch-scope.ts';
import type { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import {
	handleLaunchPromise,
	type HandledLaunchPromise,
} from '../../scripts/dev-server/handled-launch-promise.ts';

interface E2ETestRetirement {
	readonly signal: AbortSignal;
	readonly launches: Map<BridgeWebTestLaunch, boolean>;
	readonly body: HandledLaunchPromise<void>;
	readonly removeAbortListener: () => void;
}

const retirementKey = Symbol.for('agentstudio.bridge-web-e2e.retirement');
const retirementGlobal = globalThis as typeof globalThis & {
	[retirementKey]?: Map<string, E2ETestRetirement>;
};
const retirements = (retirementGlobal[retirementKey] ??= new Map());

// Capture the raw body before Vitest's timeout/cancellation wrapper detaches.
// The custom runner joins this same promise at its awaited task boundary.
export async function runBridgeWebE2ETestBody(
	context: {
		readonly signal: AbortSignal;
		readonly task: Pick<TestContext['task'], 'id' | 'name'>;
	},
	body: () => Promise<void>,
): Promise<void> {
	const launches = new Map<BridgeWebTestLaunch, boolean>();
	const signal = context.signal;
	const retireOnAbort = (): void => {
		process.stderr.write(
			`BRIDGE_E2E_ABORT waiting=body retirement: ${context.task.name}; ${[...launches.keys()].flatMap((launch) => launch.pendingStepDiagnostics).join(', ')}\n`,
		);
		for (const launch of launches.keys())
			void handleLaunchPromise(launch.dispose(), 'aborted E2E launch retirement').settled;
	};
	signal.addEventListener('abort', retireOnAbort, { once: true });
	const rawBody = handleLaunchPromise(
		runWithBridgeWebLaunchScope(
			{
				signal,
				ownLaunch: (launch, created): void => {
					launches.set(launch, (launches.get(launch) ?? false) || created);
					if (signal.aborted)
						void handleLaunchPromise(launch.dispose(), 'late aborted E2E launch').settled;
				},
			},
			body,
		),
		`E2E body ${context.task.name}`,
	);
	retirements.set(context.task.id, {
		signal,
		launches,
		body: rawBody,
		removeAbortListener: (): void => signal.removeEventListener('abort', retireOnAbort),
	});
	if (signal.aborted) retireOnAbort();
	return await rawBody.value();
}

export async function finishBridgeWebE2ETest(taskId: string, failed: boolean): Promise<void> {
	const retirement = retirements.get(taskId);
	if (retirement === undefined) return;
	const joined = new Set<BridgeWebTestLaunch>();
	const errors: unknown[] = [];
	const disposeLaunches = async (): Promise<void> => {
		// Each pass joins concrete new registrations, including work caused by a
		// retiring launch. Keep this live map until every eligible launch is joined.
		for (;;) {
			const pending = [...retirement.launches].filter(
				([launch, created]) =>
					!joined.has(launch) && (retirement.signal.aborted || failed || created),
			);
			if (pending.length === 0) return;
			for (const [launch] of pending) joined.add(launch);
			const results = await Promise.allSettled(
				pending.map(async ([launch]): Promise<void> => {
					await launch.dispose();
				}),
			);
			for (const result of results) if (result.status === 'rejected') errors.push(result.reason);
		}
	};
	try {
		// Abort disposal starts before joining the body: child/page/client closure
		// unblocks that body, whose finally may itself await the same disposal.
		const earlyDisposal =
			retirement.signal.aborted || failed
				? handleLaunchPromise(disposeLaunches(), 'E2E abort teardown')
				: null;
		const bodyOutcome = await retirement.body.settled;
		await earlyDisposal?.value();
		// Include launches acquired by a resumed, already-aborted body.
		await disposeLaunches();
		if (errors.length > 0) {
			if (bodyOutcome.kind === 'failed') errors.push(bodyOutcome.error);
			throw new AggregateError(errors, 'E2E owned launch retirement failed');
		}
		if (bodyOutcome.kind === 'failed' && retirement.signal.aborted) throw bodyOutcome.error;
	} finally {
		retirement.removeAbortListener();
		retirements.delete(taskId);
	}
}
