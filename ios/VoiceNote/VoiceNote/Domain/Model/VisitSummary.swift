import Foundation

/// AI 生成的拜访总结
/// 对齐 Android: app/src/.../domain/model/VisitSummary.kt
struct VisitSummary: Codable, Equatable {
    var topics: [String]
    var conclusions: [String]
    var todos: [TodoItem]
    var nextSteps: [String]
}

/// 待办事项
/// 对齐 Android: TodoItem
struct TodoItem: Codable, Equatable, Identifiable {
    let id: UUID
    var task: String
    var owner: String
    var deadline: String

    init(id: UUID = UUID(), task: String = "", owner: String = "", deadline: String = "") {
        self.id = id
        self.task = task
        self.owner = owner
        self.deadline = deadline
    }
}
