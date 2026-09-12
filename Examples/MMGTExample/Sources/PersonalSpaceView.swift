import MMGTAI
import MMGTCore
import MMGTSync
import SwiftUI
import UniformTypeIdentifiers

struct PersonalSpaceView: View {
  @State var model: PersonalSpaceModel
  let ownerID: UUID
  init(model: PersonalSpaceModel) {
    _model = State(initialValue: model)
    ownerID = model.viewID
  }
  @Environment(\.scenePhase) private var phase
  @State private var kind: PersonalDomain.Kind = .task
  @State private var title = ""
  @State private var bodyText = ""
  @State private var listID = ""
  @State private var prompt = ""
  @State private var selectedModel = ""
  @State private var importingFile = false
  @State private var choices: [ReplicaRecordKey: ReplicaImportAction] = [:]
  @State private var editing: EditItem?
  private struct EditItem: Identifiable {
    let row: ReplicaRecord
    var id: String { row.key.id }
  }
  private var selected: AIModelDescriptor? { model.models.first { modelKey($0) == selectedModel } }
  private func modelKey(_ model: AIModelDescriptor) -> String {
    model.connectionId + "|" + model.id
  }
  private var items: [ReplicaRecord] { model.rows.filter { $0.key.collection == kind.collection } }
  var body: some View {
    Form {
      Section("My space") {
        Text(model.profileLabel).font(.caption)
        Text(
          "Lists, tasks and notes work without an account. AI needs internet and sends the prompt, selected data and attachments to the configured provider."
        ).font(.caption)
        if !model.ready { ProgressView("Opening local data") }
        if let error = model.error {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("personal-error")
        }
        if model.canSync {
          Button("Synchronize") {
            Task { await model.perform(viewID: ownerID) { try await model.synchronize() } }
          }
          .disabled(model.syncing)
          Button("Review guest data") {
            Task { await model.perform(viewID: ownerID) { try await model.reviewImport() } }
          }.disabled(model.syncing)
        }
      }
      if let plan = model.plan, !plan.committed {
        Section("Bring guest data into this account") {
          Text(
            "\(plan.items.count) local records. The original guest copy is retained. Choose how to handle every colliding identifier."
          )
          ForEach(plan.items.filter { $0.target != nil }, id: \.source.key) { item in
            Picker(
              item.source.data?["title"]?.string ?? item.source.key.id,
              selection: Binding(
                get: { choices[item.source.key]?.rawValue ?? "" },
                set: { choices[item.source.key] = ReplicaImportAction(rawValue: $0) })
            ) {
              Text("Choose an action").tag("")
              Text("Keep account version").tag(ReplicaImportAction.keepTarget.rawValue)
              Text("Use guest version").tag(ReplicaImportAction.replaceTarget.rawValue)
            }
          }
          Button("Confirm import") {
            Task {
              await model.perform(viewID: ownerID) {
                try await model.approveImport(choices: choices)
                try await model.synchronize()
              }
            }
          }
          Button("Keep separate") { model.deferImport() }
        }
      }
      Section("Personal items") {
        Picker("Item type", selection: $kind) {
          ForEach(PersonalDomain.Kind.allCases, id: \.self) {
            Text($0.rawValue.capitalized).tag($0)
          }
        }
        TextField("Item title", text: $title).accessibilityIdentifier("personal-title")
        if kind == .note { TextField("Note body", text: $bodyText, axis: .vertical) }
        if kind != .list {
          Picker("List", selection: $listID) {
            Text("No list").tag("")
            ForEach(model.rows.filter { $0.key.collection == "personal_lists" }, id: \.key) {
              Text($0.data?["title"]?.string ?? $0.key.id).tag($0.key.id)
            }
          }
        }
        Button("Add \(kind.rawValue)") {
          let selectedKind = kind
          let text = title
          let note = bodyText
          let parent = listID.isEmpty ? nil : listID
          Task {
            await model.perform(viewID: ownerID) {
              guard let domain = model.domain else { return }
              _ = try await domain.create(
                kind: selectedKind, title: text, body: note,
                listID: selectedKind == .list ? nil : parent)
              title = ""
              bodyText = ""
            }
          }
        }.disabled(!model.ready || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        ForEach(items, id: \.key) { row in
          VStack(alignment: .leading, spacing: 8) {
            if kind == .task {
              Toggle(
                row.data?["title"]?.string ?? row.key.id,
                isOn: Binding(
                  get: { row.data?["completed"]?.bool ?? false },
                  set: { value in
                    Task {
                      await model.perform(viewID: ownerID) {
                        try await model.domain?.complete(id: row.key.id, completed: value)
                      }
                    }
                  }))
            } else {
              Text(row.data?["title"]?.string ?? row.key.id).font(.headline)
            }
            if let text = row.data?["body"]?.string, !text.isEmpty {
              Text(text).textSelection(.enabled)
            }
            Text(
              row.issues.isEmpty
                ? (model.isGuest
                  ? "Saved on this device"
                  : (row.pending ? "Saved locally · awaiting sync" : "Saved"))
                : "Needs reconciliation"
            ).font(.caption)
            HStack {
              Button("Edit") { editing = .init(row: row) }
              Button("Delete", role: .destructive) {
                let selectedKind = kind
                Task {
                  await model.perform(viewID: ownerID) {
                    try await model.domain?.remove(kind: selectedKind, id: row.key.id)
                  }
                }
              }
            }.buttonStyle(.borderless)
            if !row.issues.isEmpty {
              Button("Use account version") {
                Task {
                  await model.perform(viewID: ownerID) {
                    try await model.resolve(row, keepLocal: false)
                  }
                }
              }
              Button("Retry this local version") {
                Task {
                  await model.perform(viewID: ownerID) {
                    try await model.resolve(row, keepLocal: true)
                  }
                }
              }
            }
          }
        }
      }
      Section("Assistant") {
        Button("Load available models") {
          Task { await model.perform(viewID: ownerID) { try await model.loadModels() } }
        }
        Picker("AI model", selection: $selectedModel) {
          Text("Choose explicitly").tag("")
          ForEach(model.models.indices, id: \.self) { index in
            let item = model.models[index]
            Text(item.displayName + " · " + String(item.connectionId.prefix(8))).tag(modelKey(item))
          }
        }
        ForEach(
          model.rows.filter { $0.key.collection == "personal_chat_messages" }.sorted {
            ($0.data?["createdAt"]?.string ?? "", $0.key.id) < (
              $1.data?["createdAt"]?.string ?? "", $1.key.id
            )
          }, id: \.key
        ) { row in
          VStack(alignment: .leading) {
            Text(row.data?["role"]?.string ?? "message").font(.caption.bold())
            Text(row.data?["text"]?.string ?? "").textSelection(.enabled)
            if row.data?["status"]?.string != "completed" {
              Text("Incomplete · not retried").font(.caption)
            }
          }
        }
        if model.runningAI { Text(model.streamingText).accessibilityIdentifier("personal-stream") }
        TextField("Assistant message", text: $prompt, axis: .vertical)
        Button("Attach a temporary file or image") { importingFile = true }.disabled(
          model.runningAI)
        ForEach(model.uploads, id: \.id) { upload in
          Text("\(upload.contentType) · expires \(upload.expiresAt)").font(.caption)
          Button("Remove attachment") {
            Task {
              await model.perform(viewID: ownerID) { try await model.removeUpload(upload.id) }
            }
          }
        }
        Button("Send") {
          if model.viewID == ownerID, let selected {
            model.ask(prompt, model: selected)
            prompt = ""
          }
        }.disabled(model.runningAI || selected == nil || prompt.isEmpty)
        if model.runningAI { Button("Stop") { model.cancelAI() } }
        Button("Start a new expired guest AI session") {
          Task { await model.perform(viewID: ownerID) { try await model.restartGuestAI() } }
        }
      }
    }
    .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item]) { result in
      Task { await model.perform(viewID: ownerID) { try await model.upload(result.get()) } }
    }
    .alert(
      "Apply this local change?",
      isPresented: Binding(
        get: { model.confirmation != nil }, set: { if !$0 { model.decide(false) } })
    ) {
      Button("Apply change") { model.decide(true) }
      Button("Cancel", role: .cancel) { model.decide(false) }
    } message: {
      Text(model.confirmation?.message ?? "")
    }
    .sheet(item: $editing) { edit in PersonalEditView(model: model, row: edit.row, ownerID: ownerID)
    }
    .task(id: phase) {
      guard phase == .active else { return }
      while !Task.isCancelled {
        await model.perform(viewID: ownerID) { try await model.synchronize() }
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
      }
    }
  }
}
private struct PersonalEditView: View {
  let model: PersonalSpaceModel
  let row: ReplicaRecord
  let ownerID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var bodyText = ""
  var body: some View {
    NavigationStack {
      Form {
        TextField("Title", text: $title)
        if row.key.collection == "personal_notes" {
          TextField("Body", text: $bodyText, axis: .vertical)
        }
      }
      .navigationTitle("Edit local item")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              await model.perform(viewID: ownerID) {
                let kind: PersonalDomain.Kind =
                  row.key.collection == "personal_lists"
                  ? .list : (row.key.collection == "personal_tasks" ? .task : .note)
                try await model.domain?.edit(
                  kind: kind, id: row.key.id, title: title, body: bodyText)
                dismiss()
              }
            }
          }
        }
      }.onAppear {
        title = row.data?["title"]?.string ?? ""
        bodyText = row.data?["body"]?.string ?? ""
      }
    }
  }
}
