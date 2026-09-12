import MMGTAI
import MMGTAuth
import MMGTCore
import MMGTSwiftUI
import SwiftUI

@main struct MMGTExampleApp: App {
  private let setup: Result<ExampleModel, any Error>
  init() { setup = Result { try ExampleModel(config: ExampleConfiguration.load()) } }
  var body: some Scene {
    WindowGroup {
      switch setup {
      case .success(let model): ExampleView(model: model)
      case .failure(let error):
        ContentUnavailableView(
          "Configuration unavailable", systemImage: "gearshape",
          description: Text(error.localizedDescription))
      }
    }
  }
}

struct ExampleView: View {
  @State var model: ExampleModel
  @State private var email = ""
  @State private var password = ""
  @State private var code = ""
  @State private var note = ""
  @State private var connection = ""
  @State private var aiModel = ""
  @State private var prompt = "Reply with one short sentence."
  @State private var newEmail = ""
  @State private var currentPassword = ""
  var body: some View {
    NavigationStack {
      TabView {
        Tab("My space", systemImage: "square.and.pencil") {
          PersonalSpaceView(model: model.personal).id(model.personal.viewID)
        }
        Tab("Account", systemImage: "person") { account }
        if model.auth.snapshot?.identity != nil {
          Tab("Sync", systemImage: "arrow.triangle.2.circlepath") { sync }
          Tab("Realtime", systemImage: "antenna.radiowaves.left.and.right") { realtime }
          Tab("Billing", systemImage: "creditcard") { billing }
          Tab("AI", systemImage: "bubble.left.and.text.bubble.right") { ai }
        }
      }
      .navigationTitle("MMGT SDK example")
      .safeAreaInset(edge: .bottom) {
        if let error = model.error {
          Text(error).font(.caption).padding().background(.regularMaterial)
        }
      }
    }
    .mmgtLifecycle(model.auth.session)
    .mmgtLifecycle(model.personal)
    .task { await model.auth.observe() }
    .task {
      await model.personal.perform { try await model.personal.restoreLocal() }
      if model.config.isConfigured { await model.action { try await model.auth.restore() } }
    }
    .task(id: model.auth.snapshot?.identity) {
      await model.action { try await model.connectAccount(model.auth.snapshot?.identity) }
    }
    .onOpenURL { url in try? model.authorizer.resume(url) }
  }
  private var account: some View {
    Form {
      Text(model.config.authURL.absoluteString).font(.caption)
      if !model.config.isConfigured {
        Text(
          "Copy Configuration.sample.json to Configuration.json and replace it with your application's public configuration."
        )
      }
      if let user = model.auth.snapshot?.user, model.auth.snapshot?.identity != nil {
        Text(user.email)
        Button("Refresh account details") {
          Task { await model.action { try await model.reloadAccountDetails() } }
        }
        if let details = model.accountDetails {
          Text("Sessions: \(details.sessions.count) · Passkeys: \(details.passkeys.count)")
          ForEach(details.providers, id: \.id) { provider in Text("Linked: \(provider.provider)") }
        }
        Button("Register a passkey") {
          Task { await model.action { try await model.registerPasskey() } }
        }
        Menu("Link a provider") {
          ForEach([NativeAccountProvider.google, .apple, .facebook, .github], id: \.rawValue) {
            provider in
            Button(provider.rawValue.capitalized) {
              Task { await model.action { try await model.linkProvider(provider) } }
            }
          }
        }
        Button("Cancel provider operation") { model.accountAuthorizer.cancel() }
        DisclosureGroup("Change email with password reauthentication") {
          TextField("New email", text: $newEmail).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Current password", text: $currentPassword)
          Button("Send confirmation to new email") {
            Task {
              let password = currentPassword
              currentPassword = ""
              await model.action {
                try await model.changeEmail(newEmail: newEmail, currentPassword: password)
              }
            }
          }.disabled(newEmail.isEmpty || currentPassword.isEmpty)
          if let message = model.accountMessage { Text(message).font(.caption) }
        }
        Button("Sign out") {
          Task {
            password = ""
            code = ""
            currentPassword = ""
            newEmail = ""
            await model.action { try await model.auth.logout() }
          }
        }
      } else {
        TextField("Email", text: $email).textContentType(.username).textInputAutocapitalization(
          .never
        ).autocorrectionDisabled()
        SecureField("Password", text: $password).textContentType(.password)
        Button("Sign in with password") {
          Task {
            let password = password
            self.password = ""
            await model.action {
              _ = try await model.auth.authenticate { client in
                try await client.login(input: .init(email: email, password: password))
              }
            }
          }
        }.disabled(model.auth.isWorking)
        Button("Sign in in browser") { Task { await model.action { try await model.oidcLogin() } } }
          .disabled(model.auth.isWorking)
        Button("Sign in with passkey") {
          Task { await model.action { try await model.passkeyLogin() } }
        }.disabled(model.auth.isWorking)
        if case .requiresTwoFactorSetup = model.auth.loginResult {
          Text(
            "MFA enrollment is required. Continue in the system browser to configure your account and finish sign-in. Setup credentials are not saved as a service session."
          )
        }
        if case .requiresTwoFactor(let token, let method, _) = model.auth.loginResult {
          Text("Verification: \(method)")
          TextField("Verification code", text: $code).textContentType(.oneTimeCode)
          Button("Verify") {
            Task {
              let code = code
              self.code = ""
              await model.action {
                _ = try await model.auth.authenticate { client in
                  try await client.verify2FALogin(input: .init(tempToken: token, code: code))
                }
              }
            }
          }.disabled(model.auth.isWorking)
        }
      }
      if model.auth.isWorking {
        Button("Cancel sign-in") {
          model.authorizer.cancel()
          Task { await model.action { try await model.auth.logout() } }
        }
      }
    }.disabled(!model.config.isConfigured)
  }
  private var sync: some View {
    Form {
      TextField("New note", text: $note)
      Button("Save to durable outbox") {
        Task {
          await model.action {
            try await model.saveNote(note)
            note = ""
          }
        }
      }
      Button("Synchronize") { Task { await model.action { try await model.synchronize() } } }
      if let result = model.sync?.value {
        Text(
          "Received \(result.pulled), sent \(result.pushed). More pages: \(result.hasMore ? "yes" : "no")"
        )
      }
      ForEach(model.records, id: \.id) { record in Text(record.data?["text"]?.string ?? record.id) }
      if !model.issues.isEmpty {
        Text(
          "\(model.issues.count) mutations require reconciliation. They remain stored for explicit resolution."
        )
      }
    }
  }
  private var realtime: some View {
    List {
      Text(model.realtime?.connection.rawValue ?? "idle")
      ForEach(Array(model.eventLog.enumerated()), id: \.offset) { Text($0.element) }
    }
    .task(id: model.realtime?.client.identity) { await model.action { try await model.listen() } }
    .task(id: model.realtime.map { ObjectIdentifier($0) }) { await model.realtime?.observe() }
  }
  private var billing: some View {
    Form {
      Button("Refresh access from backend") {
        Task { await model.action { _ = try await model.billing?.reload() } }
      }
      if let value = model.billing?.value { Text(String(describing: value)).font(.caption) }
      Text(
        "A checkout return URL does not grant access. Reload entitlements after returning. This example does not initiate payments automatically."
      )
    }
  }
  private var ai: some View {
    Form {
      TextField("Connection ID", text: $connection).textInputAutocapitalization(.never)
      TextField("Model", text: $aiModel).textInputAutocapitalization(.never)
      TextField("Prompt", text: $prompt, axis: .vertical)
      Button("Stream once") {
        Task {
          await model.action {
            try await model.ai?.stream(
              .init(
                connectionId: connection, model: aiModel,
                input: [.init(role: "user", content: [.text(prompt)])]))
          }
        }
      }
      Button("Cancel") { model.ai?.cancel() }
      if let state = model.ai {
        Text(String(describing: state.status))
        Text(state.text).textSelection(.enabled)
      }
    }
  }
}
