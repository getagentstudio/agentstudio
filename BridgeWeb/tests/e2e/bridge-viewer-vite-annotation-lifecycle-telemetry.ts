import type { Page } from 'playwright';
import { expect } from 'vitest';

const annotationLifecycleTelemetryTimeoutMilliseconds = 30_000;
const requiredAnnotationLifecycleStages = [
	'annotation_invalidation_received',
	'annotation_paint_started',
	'annotation_paint_terminal',
	'content_transfer_started',
	'content_transfer_terminal',
	'main_thread_install_started',
	'main_thread_install_terminal',
	'projection_convergence_started',
	'projection_query_started',
	'projection_store_started',
	'projection_store_terminal',
	'projection_validation_started',
	'projection_validation_terminal',
	'projection_query_terminal',
	'projection_convergence_terminal',
	'worker_application_started',
	'worker_application_terminal',
] as const;

export const requiredAnnotationLifecycleStageCount = requiredAnnotationLifecycleStages.length;

export async function drainAnnotationLifecycleTelemetry(page: Page): Promise<unknown> {
	const report: unknown = await page.evaluate(async (): Promise<unknown> => {
		const control: unknown = Reflect.get(globalThis, '__bridgeTelemetrySidecarControl');
		if (typeof control !== 'object' || control === null) return { kind: 'unavailable' };
		const drain: unknown = Reflect.get(control, 'drain');
		if (typeof drain !== 'function') return { kind: 'unavailable' };
		return await Reflect.apply(drain, control, []);
	});
	if (!isUnknownRecord(report) || report['kind'] !== 'report') {
		throw new Error(
			`Annotation lifecycle telemetry sidecar could not drain: ${JSON.stringify(report)}.`,
		);
	}
	return report;
}

export async function waitForCompleteAnnotationLifecycleTelemetry(props: {
	readonly operationCorrelationIds: () => readonly string[];
	readonly page: Page;
}): Promise<number> {
	const statusUrl = new URL('/__bridge-dev-telemetry/status', props.page.url()).toString();
	let completedStageCount: number | null = null;
	let latestDiagnostic: Readonly<Record<string, unknown>> = {
		kind: 'status-unavailable',
		operationCorrelationIds: props.operationCorrelationIds(),
	};
	try {
		await expect
			.poll(
				async (): Promise<boolean> => {
					const operationCorrelationIds = [...new Set(props.operationCorrelationIds())];
					const latestOperationCorrelationId = operationCorrelationIds.at(-1);
					if (latestOperationCorrelationId === undefined) return false;
					const response = await fetch(statusUrl, { cache: 'no-store' });
					if (!response.ok) {
						latestDiagnostic = {
							kind: 'status-http-error',
							operationCorrelationIds,
							status: response.status,
						};
						return false;
					}
					const body: unknown = await response.json();
					if (typeof body !== 'object' || body === null || !('recentSamples' in body)) {
						latestDiagnostic = {
							kind: 'status-malformed',
							operationCorrelationIds,
						};
						return false;
					}
					const recentSamples = body.recentSamples;
					const operationLifecycle = Reflect.get(body, 'operationLifecycle');
					if (!Array.isArray(recentSamples)) return false;
					const observedStages = new Set<string>();
					const observedStageResults: Array<{
						readonly phase: string;
						readonly result: string | null;
						readonly reason: string | null;
					}> = [];
					for (const sample of recentSamples) {
						if (typeof sample !== 'object' || sample === null || !('stringAttributes' in sample)) {
							continue;
						}
						const attributes = sample.stringAttributes;
						if (typeof attributes !== 'object' || attributes === null) continue;
						const operationId = Reflect.get(attributes, 'agentstudio.bridge.operation.id');
						const phase = Reflect.get(attributes, 'agentstudio.bridge.phase');
						if (operationId !== latestOperationCorrelationId || typeof phase !== 'string') continue;
						observedStages.add(phase);
						const result = Reflect.get(attributes, 'agentstudio.bridge.result');
						const reason = Reflect.get(attributes, 'agentstudio.bridge.result_reason');
						observedStageResults.push({
							phase,
							result: typeof result === 'string' ? result : null,
							reason: typeof reason === 'string' ? reason : null,
						});
					}
					const completedOperationIds =
						typeof operationLifecycle === 'object' && operationLifecycle !== null
							? Reflect.get(operationLifecycle, 'completedOperationIds')
							: null;
					const malformed =
						typeof operationLifecycle === 'object' && operationLifecycle !== null
							? Reflect.get(operationLifecycle, 'malformed')
							: null;
					const missingTerminals =
						typeof operationLifecycle === 'object' && operationLifecycle !== null
							? Reflect.get(operationLifecycle, 'missingTerminals')
							: null;
					const matchingMalformed = operationCorrelationIds.flatMap(
						(operationCorrelationId) =>
							matchingLifecycleEntries(malformed, operationCorrelationId) ?? [],
					);
					const matchingMissingTerminals = operationCorrelationIds.flatMap(
						(operationCorrelationId) =>
							matchingLifecycleEntries(missingTerminals, operationCorrelationId) ?? [],
					);
					const everyOperationCompleted =
						Array.isArray(completedOperationIds) &&
						operationCorrelationIds.every((operationCorrelationId) =>
							completedOperationIds.includes(operationCorrelationId),
						);
					const missingStages = requiredAnnotationLifecycleStages.filter(
						(stage) => !observedStages.has(stage),
					);
					const latestTerminalSucceeded = [
						'content_transfer_terminal',
						'projection_validation_terminal',
						'projection_query_terminal',
						'projection_convergence_terminal',
						'worker_application_terminal',
					].every((phase) =>
						observedStageResults.some(
							(stage) => stage.phase === phase && stage.result === 'success',
						),
					);
					latestDiagnostic = {
						completed: everyOperationCompleted,
						latestTerminalSucceeded,
						matchingMalformed,
						matchingMissingTerminals,
						missingStages,
						observedStageResults: observedStageResults.slice(-32),
						observedStages: [...observedStages],
						operationCorrelationIds,
					};
					if (
						missingStages.length === 0 &&
						latestTerminalSucceeded &&
						everyOperationCompleted &&
						matchingMalformed.length === 0 &&
						matchingMissingTerminals.length === 0 &&
						props.operationCorrelationIds().at(-1) === latestOperationCorrelationId
					) {
						completedStageCount = requiredAnnotationLifecycleStageCount;
						return true;
					}
					return false;
				},
				{ timeout: annotationLifecycleTelemetryTimeoutMilliseconds },
			)
			.toBe(true);
	} catch (error: unknown) {
		const sidecarSnapshot: unknown = await props.page
			.evaluate(async (): Promise<unknown> => {
				const control: unknown = Reflect.get(globalThis, '__bridgeTelemetrySidecarControl');
				if (typeof control !== 'object' || control === null) return { kind: 'unavailable' };
				const snapshot: unknown = Reflect.get(control, 'snapshot');
				if (typeof snapshot !== 'function') return { kind: 'unavailable' };
				return await Reflect.apply(snapshot, control, []);
			})
			.catch((snapshotError: unknown): unknown => ({
				kind: 'snapshot-failed',
				reason: String(snapshotError),
			}));
		throw new Error(
			`Annotation lifecycle telemetry did not complete for the saved projection: lifecycle=${JSON.stringify(
				latestDiagnostic,
			)} sidecarSnapshot=${JSON.stringify(sidecarSnapshot)}.`,
			{ cause: error },
		);
	}
	if (completedStageCount === null) {
		throw new Error('Annotation lifecycle telemetry completed without a stage count');
	}
	return completedStageCount;
}

function matchingLifecycleEntries(
	entries: unknown,
	operationCorrelationId: string,
): readonly unknown[] | null {
	return Array.isArray(entries)
		? entries.filter(
				(entry): boolean =>
					typeof entry === 'object' &&
					entry !== null &&
					Reflect.get(entry, 'operationCorrelationId') === operationCorrelationId,
			)
		: null;
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
