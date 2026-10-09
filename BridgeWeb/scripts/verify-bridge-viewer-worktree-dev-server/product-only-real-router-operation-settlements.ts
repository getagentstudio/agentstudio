/** Correlates the v2 admission, result and result acknowledgement observed by the E2E page. */
export interface ProductOpenSettlementEntry {
	readonly requestKind: string | null;
	resultAcknowledged: boolean;
	settledResponseKind: string | null;
}

interface ProductOpenResult {
	readonly responseKind: string | null;
}

export class BridgeViewerProductOpenSettlementCorrelator {
	readonly #entriesByOperationId = new Map<string, Set<ProductOpenSettlementEntry>>();
	readonly #resultByOperationId = new Map<string, ProductOpenResult>();
	readonly #acknowledgedOperationIds = new Set<string>();

	observe(entry: ProductOpenSettlementEntry, requestBody: unknown, responseBody: unknown): void {
		const request = asRecord(requestBody);
		const response = asRecord(responseBody);
		if (entry.requestKind === 'subscription.open' && response?.['kind'] === 'operation.admitted') {
			const operationId = stringValue(response['operationId']);
			if (operationId === null) return;
			const entries = this.#entriesByOperationId.get(operationId) ?? new Set();
			entries.add(entry);
			this.#entriesByOperationId.set(operationId, entries);
			this.#applyKnownSettlement(operationId, entry);
			return;
		}
		if (entry.requestKind === 'operation.result' && response?.['kind'] === 'operation.result') {
			const operationId = stringValue(response['operationId']);
			if (operationId === null || operationId !== request?.['operationId']) return;
			const result = asRecord(response['result']);
			this.#resultByOperationId.set(operationId, {
				responseKind: response['outcome'] === 'succeeded' ? stringValue(result?.['kind']) : null,
			});
			for (const entry of this.#entriesByOperationId.get(operationId) ?? []) {
				this.#applyKnownSettlement(operationId, entry);
			}
			return;
		}
		if (
			entry.requestKind !== 'operation.resultAcknowledgement' ||
			response?.['kind'] !== 'operation.resultAcknowledged'
		)
			return;
		const operationId = stringValue(response['operationId']);
		if (operationId === null || operationId !== request?.['operationId']) return;
		this.#acknowledgedOperationIds.add(operationId);
		for (const entry of this.#entriesByOperationId.get(operationId) ?? []) {
			entry.resultAcknowledged = true;
		}
	}

	#applyKnownSettlement(operationId: string, entry: ProductOpenSettlementEntry): void {
		entry.settledResponseKind = this.#resultByOperationId.get(operationId)?.responseKind ?? null;
		entry.resultAcknowledged = this.#acknowledgedOperationIds.has(operationId);
	}
}

function asRecord(value: unknown): Readonly<Record<string, unknown>> | null {
	return typeof value === 'object' && value !== null && !Array.isArray(value)
		? Object.fromEntries(Object.entries(value))
		: null;
}

function stringValue(value: unknown): string | null {
	return typeof value === 'string' ? value : null;
}
