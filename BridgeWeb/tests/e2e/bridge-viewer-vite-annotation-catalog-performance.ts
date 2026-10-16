import { spawn } from 'node:child_process';
import { join } from 'node:path';

import { type Page, type Request } from 'playwright';
import { uuidv7 } from 'uuidv7';
import { expect } from 'vitest';

import { waitForInitialAnnotationCatalogCommit } from './bridge-viewer-vite-annotation-catalog-owner-observation.ts';

export interface AnnotationCatalogTransferTelemetryObservation {
	readonly mainBeginStartTimeMilliseconds: number;
	readonly mainCommitStartTimeMilliseconds: number;
	readonly mainStagingSamples: readonly AnnotationCatalogMainStagingSample[];
	readonly maximumUnitByteCount: number;
	readonly operationCorrelationId: string;
	readonly presentationRevisionAfter: number;
	readonly presentationRevisionBefore: number;
	readonly windowCount: number;
}

export type AnnotationCatalogMainStagingSample =
	| {
			readonly kind: 'begin' | 'commit';
			readonly startTimeMilliseconds: number;
	  }
	| {
			readonly kind: 'window';
			readonly startTimeMilliseconds: number;
			readonly windowOrdinal: number;
	  };

export interface AnnotationCatalogLongTaskEntry {
	readonly durationMilliseconds: number;
	readonly name: string;
	readonly startTimeMilliseconds: number;
}

export interface AnnotationCatalogLongTaskPhase {
	readonly name: string;
	readonly startTimeMilliseconds: number;
}

export interface AnnotationCatalogLongTaskObservation {
	readonly entries: readonly AnnotationCatalogLongTaskEntry[];
	readonly phases: readonly AnnotationCatalogLongTaskPhase[];
}

export interface AnnotationProjectionQueryObservation {
	readonly acquiredSessionIds: () => readonly string[];
	readonly dispose: () => void;
	readonly sessionIdsForOperation: (operationCorrelationId: string) => readonly string[];
}

const annotationCatalogLongTaskObservationKey = 'bridgeAnnotationCatalogLongTaskObservation';

interface TelemetryStatusSample {
	readonly name: string;
	readonly numericAttributes: Readonly<Record<string, number>>;
	readonly stringAttributes: Readonly<Record<string, string>>;
}

export async function cloneSavedAnnotationMessagesIntoCompletedSession(props: {
	readonly cloneCount: number;
	readonly dataRootPath: string;
	readonly sourceMessageId: string;
	readonly sourceSessionId: string;
	readonly sourceThreadId: string;
}): Promise<() => Promise<void>> {
	const identifiers = Array.from({ length: props.cloneCount }, (): string => uuidv7());
	const statements = identifiers.map(
		(identifier): string => `
INSERT INTO annotation_message(
  id, thread_id, ordinal, author_kind, saved_body, saved_body_utf8_bytes,
  saved_revision, status, semantic_revision, created_at, updated_at,
  handled, viewed_saved_revision
)
SELECT
  '${identifier}', source.thread_id,
  (SELECT COALESCE(MAX(ordinal), -1) + 1 FROM annotation_message WHERE thread_id = source.thread_id),
  source.author_kind, source.saved_body, source.saved_body_utf8_bytes,
  source.saved_revision, source.status, source.semantic_revision,
  source.created_at, source.updated_at, source.handled, source.viewed_saved_revision
FROM annotation_message AS source
WHERE lower(source.id) = lower('${props.sourceMessageId}');`,
	);
	const captureSeedSessionState = `
CREATE TEMP TABLE seeded_session_before AS
SELECT semantic_revision, updated_at
FROM annotation_session
WHERE lower(id) = lower('${props.sourceSessionId}');`;
	const completeSeedSession = `
UPDATE annotation_session
SET lifecycle = 'completed',
    semantic_revision = semantic_revision + 1,
    updated_at = updated_at + 1,
    completed_at = updated_at + 1
WHERE lower(id) = lower('${props.sourceSessionId}');`;
	const verifyCompletedSeedSession = `
SELECT
  (SELECT COUNT(*) FROM annotation_message
   WHERE lower(thread_id) = lower('${props.sourceThreadId}'))
  || '|'
  ||
  (SELECT COUNT(*)
   FROM annotation_session AS session
   JOIN seeded_session_before AS before
   WHERE lower(session.id) = lower('${props.sourceSessionId}')
     AND session.lifecycle = 'completed'
     AND session.semantic_revision = before.semantic_revision + 1
     AND session.updated_at > before.updated_at
     AND session.completed_at = session.updated_at);`;
	const sql = [
		'.bail on',
		'PRAGMA busy_timeout = 10000;',
		captureSeedSessionState,
		'BEGIN IMMEDIATE;',
		...statements,
		completeSeedSession,
		'COMMIT;',
		verifyCompletedSeedSession,
	].join('\n');
	const result = await runSQLiteScript(join(props.dataRootPath, 'local.sqlite'), sql);
	const verification = result.trim().split('\n').at(-1);
	const expectedVerification = `${props.cloneCount + 1}|1`;
	if (verification !== expectedVerification) {
		throw new Error(
			`Large annotation catalog fixture expected ${expectedVerification} message/session verification, received ${result.trim()}.`,
		);
	}
	return async (): Promise<void> => {
		const cleanupResult = await runSQLiteScript(
			join(props.dataRootPath, 'local.sqlite'),
			[
				'.bail on',
				'PRAGMA busy_timeout = 10000;',
				'BEGIN IMMEDIATE;',
				`DELETE FROM annotation_message WHERE lower(thread_id) = lower('${props.sourceThreadId}') AND lower(id) != lower('${props.sourceMessageId}');`,
				'COMMIT;',
				`SELECT COUNT(*) FROM annotation_message WHERE lower(thread_id) = lower('${props.sourceThreadId}');`,
			].join('\n'),
		);
		const retainedMessageCount = Number(cleanupResult.trim().split('\n').at(-1));
		if (retainedMessageCount !== 1) {
			throw new Error(
				`Large annotation catalog fixture cleanup retained ${cleanupResult.trim()} messages.`,
			);
		}
	};
}

export async function latestAnnotationCatalogCommit(
	page: Page,
): Promise<{ readonly catalogRevision: number }> {
	return { catalogRevision: await waitForInitialAnnotationCatalogCommit(page) };
}

export function observeAnnotationProjectionQueries(
	page: Page,
): AnnotationProjectionQueryObservation {
	const acquiredSessionIds: string[] = [];
	const sessionIdsByOperationCorrelationId = new Map<string, string[]>();
	const handleRequest = (request: Request): void => {
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/command'
		) {
			return;
		}
		const body: unknown = request.postDataJSON();
		if (!isRecord(body) || !isRecord(body['call'])) return;
		const call = body['call'];
		if (call['method'] === 'review.annotations.command' && isRecord(call['request'])) {
			const operation = call['request']['operation'];
			if (
				isRecord(operation) &&
				operation['kind'] === 'demand.acquire' &&
				typeof operation['sessionId'] === 'string'
			) {
				acquiredSessionIds.push(operation['sessionId']);
			}
		}
		if (call['method'] !== 'review.annotations.projection.query' || !isRecord(call['request'])) {
			return;
		}
		const projectionRequest = call['request'];
		const operationCorrelationId = projectionRequest['operationCorrelationId'];
		const sessionIds = projectionRequest['sessionIds'];
		if (
			typeof operationCorrelationId !== 'string' ||
			!Array.isArray(sessionIds) ||
			!sessionIds.every((sessionId) => typeof sessionId === 'string')
		) {
			return;
		}
		sessionIdsByOperationCorrelationId.set(operationCorrelationId, sessionIds);
	};
	page.on('request', handleRequest);
	return {
		acquiredSessionIds: (): readonly string[] => acquiredSessionIds,
		dispose: (): void => {
			page.off('request', handleRequest);
		},
		sessionIdsForOperation: (operationCorrelationId): readonly string[] =>
			sessionIdsByOperationCorrelationId.get(operationCorrelationId) ?? [],
	};
}

export async function waitForAnnotationCatalogCommit(props: {
	readonly minimumCatalogRevisionExclusive: number;
	readonly page: Page;
}): Promise<AnnotationCatalogTransferTelemetryObservation> {
	let observation: AnnotationCatalogTransferTelemetryObservation | null = null;
	await expect
		.poll(
			async (): Promise<boolean> => {
				const samples = annotationCatalogSamples(await fetchTelemetryStatus(props.page));
				const commit = samples.findLast(
					(sample) =>
						sample.stringAttributes['agentstudio.bridge.phase'] ===
							'annotation_catalog_main_commit' &&
						numberAttribute(sample, 'agentstudio.bridge.annotation.catalog.revision') >
							props.minimumCatalogRevisionExclusive,
				);
				if (commit === undefined) return false;
				const operationId = commit.stringAttributes['agentstudio.bridge.operation.id'];
				if (operationId === undefined) return false;
				const operationSamples = samples.filter(
					(sample) => sample.stringAttributes['agentstudio.bridge.operation.id'] === operationId,
				);
				const begin = operationSamples.filter(
					(sample) =>
						sample.stringAttributes['agentstudio.bridge.phase'] === 'annotation_catalog_main_begin',
				);
				const windows = operationSamples.filter(
					(sample) =>
						sample.stringAttributes['agentstudio.bridge.phase'] ===
						'annotation_catalog_main_window',
				);
				if (begin.length !== 1 || windows.length < 2) return false;
				const beginSample = begin[0];
				if (beginSample === undefined) return false;
				const commitWindowCount = numberAttribute(
					commit,
					'agentstudio.bridge.annotation.catalog.window.count',
				);
				const commitEntryCount = numberAttribute(
					commit,
					'agentstudio.bridge.annotation.catalog.entry.count',
				);
				const windowEntryCount = windows.reduce(
					(total, sample) =>
						total + numberAttribute(sample, 'agentstudio.bridge.annotation.catalog.entry.count'),
					0,
				);
				if (commitWindowCount !== windows.length || commitEntryCount !== windowEntryCount) {
					return false;
				}
				const presentationRevisionBefore = numberAttribute(
					commit,
					'agentstudio.bridge.presentation.revision.before',
				);
				const presentationRevisionAfter = numberAttribute(
					commit,
					'agentstudio.bridge.presentation.revision.after',
				);
				if (
					presentationRevisionAfter !== presentationRevisionBefore + 1 ||
					[...begin, ...windows].some(
						(sample) =>
							numberAttribute(sample, 'agentstudio.bridge.presentation.revision.before') !==
								presentationRevisionBefore ||
							numberAttribute(sample, 'agentstudio.bridge.presentation.revision.after') !==
								presentationRevisionBefore,
					)
				) {
					return false;
				}
				const maximumUnitByteCount = Math.max(
					...operationSamples.map((sample) =>
						numberAttribute(sample, 'agentstudio.bridge.annotation.catalog.unit.byte_count'),
					),
				);
				if (maximumUnitByteCount > 128 * 1024) return false;
				const mainBeginStartTimeMilliseconds = numberAttribute(
					beginSample,
					'agentstudio.bridge.source.monotonic_ms',
				);
				const mainCommitStartTimeMilliseconds = numberAttribute(
					commit,
					'agentstudio.bridge.source.monotonic_ms',
				);
				observation = {
					mainBeginStartTimeMilliseconds,
					mainCommitStartTimeMilliseconds,
					mainStagingSamples: [
						{ kind: 'begin', startTimeMilliseconds: mainBeginStartTimeMilliseconds },
						...windows.map(
							(sample): AnnotationCatalogMainStagingSample => ({
								kind: 'window',
								startTimeMilliseconds: numberAttribute(
									sample,
									'agentstudio.bridge.source.monotonic_ms',
								),
								windowOrdinal: numberAttribute(
									sample,
									'agentstudio.bridge.annotation.catalog.window.ordinal',
								),
							}),
						),
						{ kind: 'commit', startTimeMilliseconds: mainCommitStartTimeMilliseconds },
					],
					maximumUnitByteCount,
					operationCorrelationId: operationId,
					presentationRevisionAfter,
					presentationRevisionBefore,
					windowCount: windows.length,
				};
				return true;
			},
			{ timeout: 120_000 },
		)
		.toBe(true);
	if (observation === null) throw new Error('Large catalog Main telemetry did not converge.');
	return observation;
}

export function annotationCatalogLongTasksOverlappingMainStaging(
	observation: AnnotationCatalogLongTaskObservation,
	transfer: AnnotationCatalogTransferTelemetryObservation,
): readonly AnnotationCatalogLongTaskEntry[] {
	return observation.entries.filter((entry) => {
		const entryEndTimeMilliseconds = entry.startTimeMilliseconds + entry.durationMilliseconds;
		return (
			entry.startTimeMilliseconds <= transfer.mainCommitStartTimeMilliseconds &&
			entryEndTimeMilliseconds >= transfer.mainBeginStartTimeMilliseconds
		);
	});
}

export async function beginAnnotationCatalogLongTaskObservation(page: Page): Promise<void> {
	const supported = await page.evaluate((key): boolean => {
		if (!PerformanceObserver.supportedEntryTypes.includes('longtask')) return false;
		const existingState = Reflect.get(window, key);
		if (typeof existingState === 'object' && existingState !== null) {
			const existingObserver = Reflect.get(existingState, 'observer');
			if (existingObserver instanceof PerformanceObserver) existingObserver.disconnect();
		}
		const state = {
			entries: [] as AnnotationCatalogLongTaskEntry[],
			observer: null as PerformanceObserver | null,
			phases: [
				{
					name: 'observer_started',
					startTimeMilliseconds: performance.now(),
				},
			] as AnnotationCatalogLongTaskPhase[],
		};
		state.observer = new PerformanceObserver((entryList): void => {
			state.entries.push(
				...entryList.getEntries().map((entry) => ({
					durationMilliseconds: entry.duration,
					name: entry.name,
					startTimeMilliseconds: entry.startTime,
				})),
			);
		});
		state.observer.observe({ entryTypes: ['longtask'] });
		Reflect.set(window, key, state);
		return true;
	}, annotationCatalogLongTaskObservationKey);
	if (!supported) {
		throw new Error('Large catalog proof requires Long Tasks observation support.');
	}
}

export async function markAnnotationCatalogLongTaskPhase(page: Page, name: string): Promise<void> {
	const recorded = await page.evaluate(
		([key, phaseName]): boolean => {
			const state = Reflect.get(window, key);
			if (typeof state !== 'object' || state === null) return false;
			const phases = Reflect.get(state, 'phases');
			if (!Array.isArray(phases)) return false;
			phases.push({ name: phaseName, startTimeMilliseconds: performance.now() });
			return true;
		},
		[annotationCatalogLongTaskObservationKey, name] as const,
	);
	if (!recorded) throw new Error('Large catalog Long Tasks observation was not active.');
}

export async function finishAnnotationCatalogLongTaskObservation(
	page: Page,
): Promise<AnnotationCatalogLongTaskObservation> {
	const observation = await page.evaluate((key): AnnotationCatalogLongTaskObservation | null => {
		const state = Reflect.get(window, key);
		if (typeof state !== 'object' || state === null) return null;
		const observer = Reflect.get(state, 'observer');
		const entries = Reflect.get(state, 'entries');
		const phases = Reflect.get(state, 'phases');
		if (
			!(observer instanceof PerformanceObserver) ||
			!Array.isArray(entries) ||
			!Array.isArray(phases)
		) {
			return null;
		}
		entries.push(
			...observer.takeRecords().map((entry) => ({
				durationMilliseconds: entry.duration,
				name: entry.name,
				startTimeMilliseconds: entry.startTime,
			})),
		);
		observer.disconnect();
		Reflect.deleteProperty(window, key);
		return { entries, phases };
	}, annotationCatalogLongTaskObservationKey);
	if (observation === null) {
		throw new Error('Large catalog Long Tasks observation was not active.');
	}
	return observation;
}

export async function settleBrowserFrames(page: Page, frameCount: number): Promise<void> {
	for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
		// oxlint-disable-next-line no-await-in-loop -- Frame settlement is an ordered observation boundary.
		await page.evaluate(async (): Promise<void> => {
			await new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => resolve());
			});
		});
	}
}

async function runSQLiteScript(databasePath: string, sql: string): Promise<string> {
	return await new Promise<string>((resolve, reject): void => {
		const sqliteProcess = spawn('/usr/bin/sqlite3', [databasePath], {
			stdio: ['pipe', 'pipe', 'pipe'],
		});
		let stdout = '';
		let stderr = '';
		sqliteProcess.stdout.setEncoding('utf8');
		sqliteProcess.stderr.setEncoding('utf8');
		sqliteProcess.stdout.on('data', (chunk: string): void => {
			stdout += chunk;
		});
		sqliteProcess.stderr.on('data', (chunk: string): void => {
			stderr += chunk;
		});
		sqliteProcess.once('error', reject);
		sqliteProcess.once('close', (exitCode): void => {
			if (exitCode === 0) {
				resolve(stdout);
				return;
			}
			reject(new Error(`Large annotation catalog fixture failed with ${exitCode}: ${stderr}`));
		});
		sqliteProcess.stdin.end(sql);
	});
}

async function fetchTelemetryStatus(page: Page): Promise<unknown> {
	const response = await fetch(new URL('/__bridge-dev-telemetry/status', page.url()));
	if (!response.ok) throw new Error(`Telemetry status failed with ${response.status}.`);
	return await response.json();
}

function annotationCatalogSamples(status: unknown): readonly TelemetryStatusSample[] {
	if (!isRecord(status) || !Array.isArray(status['recentSamples'])) return [];
	return status['recentSamples']
		.filter(isTelemetryStatusSample)
		.filter(
			(sample) =>
				sample.name === 'performance.bridge.web.annotation_lifecycle' &&
				sample.stringAttributes['agentstudio.bridge.viewer'] === 'review' &&
				sample.stringAttributes['agentstudio.bridge.phase']?.startsWith(
					'annotation_catalog_main_',
				) === true,
		);
}

function isTelemetryStatusSample(value: unknown): value is TelemetryStatusSample {
	return (
		isRecord(value) &&
		typeof value['name'] === 'string' &&
		isNumberRecord(value['numericAttributes']) &&
		isStringRecord(value['stringAttributes'])
	);
}

function numberAttribute(sample: TelemetryStatusSample, key: string): number {
	const value = sample.numericAttributes[key];
	if (value === undefined) throw new Error(`Missing telemetry number ${key}.`);
	return value;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isNumberRecord(value: unknown): value is Readonly<Record<string, number>> {
	return isRecord(value) && Object.values(value).every((entry) => typeof entry === 'number');
}

function isStringRecord(value: unknown): value is Readonly<Record<string, string>> {
	return isRecord(value) && Object.values(value).every((entry) => typeof entry === 'string');
}
