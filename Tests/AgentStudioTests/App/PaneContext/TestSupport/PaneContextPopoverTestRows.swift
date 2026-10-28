import AgentStudioSharedComponents

extension MessagesPopoverModel {
    var messageRows: [MessageRowModel] {
        groups.flatMap(\.items).compactMap {
            if case .message(let row) = $0 { return row }
            return nil
        }
    }
}
