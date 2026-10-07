import Foundation

package struct ElicitationSchema: Sendable, Equatable {
    package let properties: [ElicitationProperty]
    package let required: [String]

    package init(
        properties: [ElicitationProperty],
        required: [String]
    ) {
        self.properties = properties
        self.required = required
    }
}

package struct ElicitationProperty: Sendable, Equatable {
    package let name: String
    package let title: String?
    package let description: String?
    package let type: ElicitationPropertyType

    package init(
        name: String,
        title: String?,
        description: String?,
        type: ElicitationPropertyType
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.type = type
    }
}

package struct ElicitationStringConstraints: Sendable, Equatable {
    package let choices: [String]?
    package let minLength: Int?
    package let maxLength: Int?
    package let format: ElicitationStringFormat?

    package init(
        choices: [String]?,
        minLength: Int?,
        maxLength: Int?,
        format: ElicitationStringFormat?
    ) {
        self.choices = choices
        self.minLength = minLength
        self.maxLength = maxLength
        self.format = format
    }
}

package struct ElicitationNumberConstraints: Sendable, Equatable {
    package let minimum: Double?
    package let maximum: Double?

    package init(
        minimum: Double?,
        maximum: Double?
    ) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

package struct ElicitationValues: Sendable, Equatable {
    package let properties: [String: ElicitationValue]

    package init(
        properties: [String: ElicitationValue]
    ) {
        self.properties = properties
    }
}

package enum ElicitationPropertyType: Sendable, Equatable {
    case string(ElicitationStringConstraints)
    case number(ElicitationNumberConstraints)
    case integer(ElicitationNumberConstraints)
    case boolean
}
package enum ElicitationStringFormat: Sendable, Equatable {
    case email
    case uri
    case date
}
package enum ElicitationValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
}
