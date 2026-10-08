import Foundation

package struct AskChoiceModel: Sendable, Equatable {
    package let id: String
    package let label: String
    package let control: PaneContextControlModel

    package init(id: String, label: String, control: PaneContextControlModel) {
        self.id = id
        self.label = label
        self.control = control
    }

}

package enum AskFormModel: Sendable, Equatable {
    case choice(options: [AskChoiceModel], allowsMultiple: Bool)
    case freeText(placeholder: String?)
    case elicitation([ElicitationPropertyModel])
}
package struct ElicitationPropertyModel: Sendable, Equatable {
    package let name: String
    package let title: String?
    package let description: String?
    package let required: Bool
    package let kind: ElicitationPropertyKindModel

    package init(name: String, title: String?, description: String?, required: Bool, kind: ElicitationPropertyKindModel)
    {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
        self.kind = kind
    }

}

package enum ElicitationPropertyKindModel: Sendable, Equatable {
    case string(choices: [String]?, minLength: Int?, maxLength: Int?, format: ElicitationStringFormatModel?)
    case number(minimum: Double?, maximum: Double?)
    case integer(minimum: Double?, maximum: Double?)
    case boolean
}
package enum ElicitationStringFormatModel: Sendable, Equatable {
    case email
    case uri
    case date
}
package enum AskAnswerModel: Sendable, Equatable {
    case choices([String])
    case text(String)
    case form([String: ElicitationValueModel])
}
package enum ElicitationValueModel: Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
}
package enum AskReasonModel: Sendable, Equatable {
    case approval
    case question
    case blocked
}
package enum AskWaitingModel: Sendable, Equatable {
    case nonBlocking
    case blocking(deadline: Date)
}
package enum AnswerReceiptModel: Sendable, Equatable {
    case notYetConfirmed
    case confirmed(at: Date)
    case unconfirmed
}
package enum AnswerPersonModel: Sendable, Equatable {
    case localUser
}
package enum AskStateModel: Sendable, Equatable {
    case open
    case answered(by: AnswerPersonModel, value: AskAnswerModel, receipt: AnswerReceiptModel)
    case handedBack
    case dismissed
    case expired
    case withdrawn
    case stale
}
