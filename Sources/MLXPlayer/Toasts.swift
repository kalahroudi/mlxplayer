import SwiftUI

/// A short message about something that finished in the background.
struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?
    var actionTitle: String?
    var screen: Screen?

    static func == (l: Toast, r: Toast) -> Bool { l.id == r.id }
}

/// Stack of toasts at the bottom right of the window. Long tasks never block the UI; they report here when done.
struct ToastHost: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { toast in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(toast.kind)).foregroundStyle(color(toast.kind)).font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        if let d = toast.detail {
                            Text(d).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let a = toast.actionTitle, let screen = toast.screen {
                            Button(a) { nav.screen = screen; model.dismiss(toast.id) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentIndigo)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 6)
                    Button { model.dismiss(toast.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(width: 340, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(18)
        .animation(.easeOut(duration: 0.2), value: model.toasts)
    }

    private func symbol(_ k: Toast.Kind) -> String {
        switch k { case .info: return "info.circle.fill"; case .success: return "checkmark.circle.fill"; case .error: return "exclamationmark.triangle.fill" }
    }
    private func color(_ k: Toast.Kind) -> Color {
        switch k { case .info: return .accentIndigo; case .success: return .good; case .error: return .bad }
    }
}
