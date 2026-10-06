import Foundation

package enum SessionsEvidenceReducer {
    static func admissionOrder(_ left: SessionsEvidenceRecord, _ right: SessionsEvidenceRecord) -> Bool {
        switch (left.admissionSequence, right.admissionSequence) {
        case (.none, .some): return true
        case (.some, .none): return false
        case (.some(let leftSequence), .some(let rightSequence)):
            if leftSequence != rightSequence { return leftSequence < rightSequence }
        case (.none, .none): break
        }
        if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
        return left.recordId.uuidString < right.recordId.uuidString
    }
}
