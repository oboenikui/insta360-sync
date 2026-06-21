import SwiftUI

struct LocationPermissionBanner: View {
    private var auth = LocationAuthorization.shared

    var body: some View {
        if !auth.isAuthorized {
            VStack(alignment: .leading, spacing: 6) {
                Text(auth.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                if let title = auth.actionButtonTitle {
                    Button(title) {
                        auth.requestAuthorization()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
