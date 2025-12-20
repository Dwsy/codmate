import SwiftUI

struct ProjectSpecificOverviewContainerView: View {
    @ObservedObject var sessionListViewModel: SessionListViewModel
    var project: Project
    var onSelectSession: (SessionSummary) -> Void
    var onResumeSession: (SessionSummary) -> Void
    var onFocusToday: () -> Void
    var onEditProject: (Project) -> Void

    @StateObject private var projectOverviewViewModel: ProjectOverviewViewModel

    init(sessionListViewModel: SessionListViewModel, project: Project, onSelectSession: @escaping (SessionSummary) -> Void, onResumeSession: @escaping (SessionSummary) -> Void, onFocusToday: @escaping () -> Void, onEditProject: @escaping (Project) -> Void) {
        self.sessionListViewModel = sessionListViewModel
        self.project = project
        self.onSelectSession = onSelectSession
        self.onResumeSession = onResumeSession
        self.onFocusToday = onFocusToday
        self.onEditProject = onEditProject
        _projectOverviewViewModel = StateObject(wrappedValue: ProjectOverviewViewModel(sessionListViewModel: sessionListViewModel, project: project))
    }
    
    var body: some View {
        ProjectOverviewView(
            viewModel: projectOverviewViewModel,
            project: project,
            onSelectSession: onSelectSession,
            onResumeSession: onResumeSession,
            onFocusToday: onFocusToday,
            onSelectDate: { date in
                sessionListViewModel.setSelectedDay(date)
            },
            onEditProject: onEditProject
        )
        // Update the project in the ViewModel if it changes from outside
        .onChange(of: project) { newProject in
            projectOverviewViewModel.updateProject(newProject)
        }
    }
}
