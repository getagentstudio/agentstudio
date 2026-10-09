export interface BridgePaneFailedStartFact {
	readonly kind: 'failedStart';
	readonly cause:
		| 'configurationUnavailable'
		| 'readyAcknowledgementFailed'
		| 'bootstrapBudgetExhausted';
}
