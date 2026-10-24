import SwiftUI

@main
struct LiteLLMUsageMenuBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePopover().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("로그인 설정", id: "login-settings") {
            SettingsView().environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        switch store.state {
        case let .ready(snapshot):
            Text("🚅 \(snapshot.percentage.formatted(.number.precision(.fractionLength(0))))%")
                .accessibilityLabel("LiteLLM 사용량 \(snapshot.percentage.formatted(.number.precision(.fractionLength(0))))퍼센트")
        case .loading:
            Text("🚅 ...").accessibilityLabel("LiteLLM 사용량 확인 중")
        case .needsKey:
            Text("🚅 --").accessibilityLabel("LiteLLM 사용량 로그인이 필요합니다")
        case .unavailable:
            Text("🚅 !").accessibilityLabel("LiteLLM 사용량을 표시할 수 없습니다")
        case .failure:
            Text("🚅 !").accessibilityLabel("LiteLLM 사용량 조회 오류")
        }
    }
}
