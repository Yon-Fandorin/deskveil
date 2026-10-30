/// A successful permission repair cannot clear a different component's failure.
struct AppIssues {
    enum Owner: Hashable { case input, emergency, shortcut, lid, brightness, display, power, idle, session, identification }
    private var values: [Owner: String] = [:]
    subscript(_ owner: Owner) -> String? {
        get { values[owner] }
        set { values[owner] = newValue }
    }
    var current: String? {
        let priority: [Owner] = [.emergency, .input, .shortcut, .lid, .session, .brightness, .display, .power, .idle, .identification]
        return priority.lazy.compactMap { values[$0] }.first
    }
}
