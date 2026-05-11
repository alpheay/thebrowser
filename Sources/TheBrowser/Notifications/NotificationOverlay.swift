import SwiftUI

/// Stack of toasts anchored to the configured corner of the window. Drop
/// this once at the top of the window's ZStack — it sizes to fill and
/// places its children using the user's preferred corner.
struct NotificationOverlay: View {
    @ObservedObject var center: AppNotificationCenter = .shared

    @AppStorage(PreferenceKey.notificationCorner)
    private var cornerRaw: String = NotificationCorner.topRight.rawValue

    private var corner: NotificationCorner {
        NotificationCorner(rawValue: cornerRaw) ?? .topRight
    }

    var body: some View {
        ZStack(alignment: corner.alignment) {
            // Spacer plate so the ZStack fills the window without painting.
            Color.clear

            VStack(spacing: 8) {
                let toasts = corner.isTop ? center.visible : center.visible.reversed()
                ForEach(toasts) { notification in
                    NotificationToast(notification: notification) {
                        withAnimation(Motion.springSnap) {
                            center.dismiss(notification.id)
                        }
                    }
                    .transition(toastTransition)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, corner.isTop ? topPadding : 14)
            .padding(.bottom, corner.isTop ? 14 : 14)
            .animation(Motion.springSnap, value: center.visible)
        }
        .allowsHitTesting(!center.visible.isEmpty)
    }

    /// Top corners need extra room so toasts don't crash into the toolbar
    /// or the traffic-light buttons. Sits just below the toolbar plate.
    private var topPadding: CGFloat {
        Metrics.toolbarHeight + 10
    }

    private var toastTransition: AnyTransition {
        let edge = corner.entryEdge
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }
}
