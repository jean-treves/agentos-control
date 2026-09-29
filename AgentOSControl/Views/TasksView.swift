import SwiftUI

/// Tasks: status, add (`source=app`, set by the server), cancel, pause, resume.
struct TasksView: View {
    @Environment(ControlModel.self) private var model
    @State private var tasks: [AgentTask] = []
    @State private var error: String?
    @State private var showingNewTask = false
    @State private var filter = TaskFilter.inProgress

    var body: some View {
        List(shown) { task in
            HStack {
                VStack(alignment: .leading) {
                    Text(task.title).font(.headline).lineLimit(1)
                    Text([task.status, task.pausedReason, task.engine, task.profile, task.project]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(TaskAction.available(for: task.status), id: \.self) { action in
                    Button(action.label) { Task { await perform(action, on: task) } }
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                let empty = filter.emptyState(total: tasks.count)
                ContentUnavailableView {
                    Label((tasks.isEmpty ? error : nil) ?? empty.title, systemImage: "checklist")
                } description: {
                    if let detail = empty.detail { Text(detail) }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Picker("Afficher", selection: $filter) {
                    ForEach(TaskFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding([.horizontal, .top], 8)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Nouvelle tâche…", systemImage: "plus") { showingNewTask = true }
            }
            .padding(8)
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskSheet { draft in await create(draft) }
        }
        .task { await pollEvery(.seconds(5)) { await load() } }
    }

    private var shown: [AgentTask] { filter.apply(to: tasks) }

    private func load() async {
        do {
            tasks = try await model.client.tasks()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: TaskAction, on task: AgentTask) async {
        do {
            _ = try await model.client.taskAction(id: task.taskId, action: action)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Returns true when the task was created (the sheet closes).
    private func create(_ draft: NewTask) async -> Bool {
        do {
            _ = try await model.client.createTask(draft)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

private struct NewTaskSheet: View {
    let submit: (NewTask) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewTask(title: "", prompt: "", project: "", engine: "claude", profile: "explore")
    @State private var sending = false

    var body: some View {
        Form {
            TextField("Titre", text: $draft.title)
            TextField("Projet (ex. quant/ai-infra-model-drift)", text: $draft.project)
            Picker("Moteur", selection: $draft.engine) {
                Text("claude").tag("claude")
                Text("hermes").tag("hermes")
            }
            Picker("Profil", selection: $draft.profile) {
                Text("explore").tag("explore")
                Text("ask").tag("ask")
                Text("trusted").tag("trusted")
            }
            TextEditor(text: $draft.prompt).frame(minHeight: 120)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Créer") {
                    sending = true
                    Task {
                        if await submit(draft) { dismiss() }
                        sending = false
                    }
                }
                .disabled(!draft.isSubmittable || sending)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}
