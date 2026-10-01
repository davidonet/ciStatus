import CIStatusKit
import SwiftUI

/// The menu bar label. It must observe the monitor itself, otherwise the body
/// is only evaluated once at launch and the icon never changes colour.
struct StatusIcon: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Image(nsImage: StatusDot.image(for: monitor.overall))
    }
}
