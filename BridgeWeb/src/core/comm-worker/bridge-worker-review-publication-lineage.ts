export type ReviewMetadataLineageRelationship = 'ambiguous' | 'newer' | 'older' | 'same';

export interface ReviewMetadataLineage {
	readonly generation: number;
	readonly packageId: string;
	readonly publicationId: string;
	readonly revision: number;
	readonly sourceIdentity: string;
}

export function compareReviewMetadataLineages(
	candidate: ReviewMetadataLineage,
	acceptedFloor: ReviewMetadataLineage,
): ReviewMetadataLineageRelationship {
	if (candidate.generation < acceptedFloor.generation) return 'older';
	if (candidate.generation > acceptedFloor.generation) return 'newer';
	if (
		candidate.packageId !== acceptedFloor.packageId ||
		candidate.sourceIdentity !== acceptedFloor.sourceIdentity
	) {
		return 'ambiguous';
	}
	if (candidate.revision < acceptedFloor.revision) return 'older';
	if (candidate.revision > acceptedFloor.revision) return 'newer';
	if (candidate.publicationId !== acceptedFloor.publicationId) return 'ambiguous';
	return 'same';
}
