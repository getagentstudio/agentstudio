import Foundation

enum BridgeProductSchemeMetadataDecodeRefusalReason: String, CaseIterable, Sendable {
    case duplicateObjectMember = "metadata_request_duplicate_object_member"
    case inputExceedsCeiling = "metadata_request_input_exceeds_ceiling"
    case invalidJSON = "metadata_request_invalid_json"
    case invalidUTF8 = "metadata_request_invalid_utf8"
    case nestingExceedsCeiling = "metadata_request_nesting_exceeds_ceiling"
    case objectMemberCountExceedsCeiling = "metadata_request_member_count_exceeds_ceiling"

    init?(error: any Error) {
        guard let decodeError = error as? BridgeProductStrictJSONError else { return nil }
        switch decodeError {
        case .duplicateObjectMember:
            self = .duplicateObjectMember
        case .inputExceedsCeiling:
            self = .inputExceedsCeiling
        case .invalidJSON:
            self = .invalidJSON
        case .invalidUTF8:
            self = .invalidUTF8
        case .nestingExceedsCeiling:
            self = .nestingExceedsCeiling
        case .objectMemberCountExceedsCeiling:
            self = .objectMemberCountExceedsCeiling
        }
    }
}
