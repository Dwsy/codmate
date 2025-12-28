import Foundation

@MainActor
final class DockOpenCoordinator {
  static let shared = DockOpenCoordinator()

  struct PendingNewProjectRequest: Sendable, Equatable {
    let directory: String
    let name: String?
  }

  private var pendingNewProject: PendingNewProjectRequest? = nil
  private var isContentViewReady = false

  /// Mark that ContentView has completed initialization and is ready to handle new project requests
  func markContentViewReady() {
    isContentViewReady = true
    // If there's a pending request, notify now that view is ready
    if let request = pendingNewProject {
      NotificationCenter.default.post(
        name: .codMateOpenNewProject,
        object: nil,
        userInfo: [
          "directory": request.directory,
          "name": request.name ?? ""
        ]
      )
    }
  }

  func enqueueNewProject(directory: String, name: String?) {
    let trimmedDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDir.isEmpty else { return }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = PendingNewProjectRequest(
      directory: trimmedDir,
      name: (trimmedName?.isEmpty == false) ? trimmedName : nil
    )
    pendingNewProject = request

    // Only send notification if ContentView is ready (runtime scenario)
    // Otherwise queue it for onAppear consumption (first launch scenario)
    if isContentViewReady {
      NotificationCenter.default.post(
        name: .codMateOpenNewProject,
        object: nil,
        userInfo: [
          "directory": request.directory,
          "name": request.name ?? ""
        ]
      )
    }
  }

  func consumePendingNewProject() -> PendingNewProjectRequest? {
    let request = pendingNewProject
    pendingNewProject = nil
    return request
  }
}
