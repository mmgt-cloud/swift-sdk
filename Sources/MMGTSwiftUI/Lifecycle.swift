import MMGTCore
import SwiftUI

private struct LifecycleModifier: ViewModifier {
  @Environment(\.scenePhase) private var phase
  let participants: [any ApplicationLifecycleParticipant]
  func body(content: Content) -> some View {
    content.task(id: phase) {
      let activity: ApplicationActivity
      switch phase {
      case .active: activity = .active
      case .background: activity = .background
      default: activity = .inactive
      }
      for participant in participants {
        guard !Task.isCancelled else { return }
        await participant.activityChanged(activity)
      }
    }
  }
}

extension View {
  /// Attach once to the application scene root. No service is implicitly created or connected.
  public func mmgtLifecycle(_ participants: any ApplicationLifecycleParticipant...) -> some View {
    modifier(LifecycleModifier(participants: participants))
  }
}
