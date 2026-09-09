# ``MMGTSwiftUI``

Connect application activity to SDK lifecycle participants.

Apply `mmgtLifecycle` to a view that owns the active account session. The modifier maps scene activity to `ApplicationLifecycleParticipant`. The module depends only on Core; selecting it does not force every service into the application.

Use the observable state models from the service modules with SwiftUI state/environment bindings. Start `AuthState.observe` and `RealtimeState.observe` from view tasks and let task cancellation stop observation. Account changes require fresh service clients and state instances.

All screens belong to the application. The example project demonstrates one possible interface; it is not a packaged authentication or billing UI.

Background transitions may close sockets and cancel requests. Active transitions can reconnect desired Realtime connections, but neither SwiftUI nor this adapter guarantees execution while iOS suspends the process.

<!-- compiled-quickstart -->
## Compiled quickstart

```swift
import SwiftUI
import MMGTAuth
import MMGTSwiftUI

@MainActor struct SessionStatusView: View {
  @State var state: AuthState
  var body: some View {
    Text(state.snapshot?.identity == nil ? "Signed out" : "Signed in")
      .task { await state.observe() }
      .mmgtLifecycle(state)
  }
}
```
<!-- end-compiled-quickstart -->
