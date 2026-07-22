import Foundation

/// An image sent alongside a message, already encoded for the API.
struct ImageAttachment: Equatable {
    let mediaType: String
    let base64: String
    let fileName: String
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    /// Stable, user-facing identifier for one user request. Persisted with
    /// history so logs and later conversations can refer to the exact task.
    var taskID: String? = nil
    /// What the user typed / the assistant said — this is what the UI shows.
    var text: String
    /// Attachment context (file paths/contents) sent to the model but never
    /// rendered in the bubble: the user just selected those files themselves.
    var promptContext: String?
    var images: [ImageAttachment] = []
    var isStreaming: Bool = false
}
