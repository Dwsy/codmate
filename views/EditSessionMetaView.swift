import SwiftUI

struct EditSessionMetaView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case title
        case comment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit Session")
                    .font(.title3).bold()
                Spacer()

                // Generate button (icon only, transparent background)
                if let session = viewModel.editingSession {
                    Button(action: {
                        Task { @MainActor in
                            await viewModel.generateTitleAndComment(for: session, force: false)
                        }
                    }) {
                        if viewModel.isGeneratingTitleComment && viewModel.generatingSessionId == session.id {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Generate title and comment using AI")
                    .disabled(viewModel.isGeneratingTitleComment && viewModel.generatingSessionId == session.id)
                }
            }

            TextField("Name (optional)", text: $viewModel.editTitle)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .title)

            VStack(alignment: .leading, spacing: 8) {
                Text("Comment (optional)").font(.subheadline)
                TextEditor(text: $viewModel.editComment)
                    .font(.body)
                    .codmatePlainTextEditorStyleIfAvailable()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8) // use outer padding; avoid inner padding that can clip first baseline on macOS
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .focused($focusedField, equals: .comment)
            }

            HStack {
                Button("Cancel") { viewModel.cancelEdits() }
                Spacer()
                Button("Save") { Task { await viewModel.saveEdits() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .onAppear {
            // Set focus to title field when view appears
            focusedField = .title
        }
    }
}
