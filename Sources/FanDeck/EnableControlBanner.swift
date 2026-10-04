//  EnableControlBanner.swift — "팬 제어 켜기" 안내 배너
//
//  처음 쓰는 사람에게 터미널 명령을 보여주는 건 사실상 "쓰지 말라"는 말이다.
//  버튼 한 번 → macOS 표준 암호 창 → 끝. 그 이상 설명하지 않는다.

import SwiftUI

struct EnableControlBanner: View {
    @Bindable var model: AppModel
    @StateObject private var installer = HelperInstaller.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if installer.isInstalling {
                ProgressView().controlSize(.small)
            } else if installer.canInstall {
                Button(action: enable) {
                    Text(model.helperOutdated ? L.t("업데이트", "Update") : L.t("팬 제어 켜기", "Enable fan control"))
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(iconColor.opacity(0.12))
        }
    }

    private var iconName: String {
        switch installer.state {
        case .failed:     return "exclamationmark.triangle.fill"
        case .installing: return "arrow.down.circle"
        default:          return "fan.fill"
        }
    }

    private var iconColor: Color {
        if case .failed = installer.state { return .red }
        return .orange
    }

    private var title: String {
        switch installer.state {
        case .installing: return model.helperOutdated ? "업데이트 중입니다" : "켜는 중입니다"
        case .failed:     return model.helperOutdated ? "업데이트하지 못했습니다" : "켜지 못했습니다"
        default:
            return model.helperOutdated
                ? L.t("백그라운드 서비스가 앱보다 오래되었습니다", "The background service is older than the app")
                : L.t("팬 제어가 아직 켜지지 않았습니다", "Fan control is not enabled yet")
        }
    }

    private var message: String {
        switch installer.state {
        case .installing:
            return L.t("잠시만 기다려 주세요.", "Just a moment…")
        case .failed(let reason):
            return reason
        default:
            if model.helperOutdated {
                return L.t("새로 생긴 설정이 저장되지 않습니다. 업데이트하면 해결됩니다. macOS 암호 창이 한 번 뜹니다.", "New settings are not being saved. Updating fixes it. macOS will ask for your password once.")
            }
            if installer.canInstall {
                return L.t("켜면 팬 속도를 직접 정할 수 있습니다. macOS 암호 창이 한 번 뜹니다. 온도 보기는 켜지 않아도 됩니다.", "Enables direct fan speed control. macOS will ask for your password once. Monitoring works without it.")
            }
            return L.t("앱을 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요.", "Move the app to Applications and reopen it.")
        }
    }

    private func enable() {
        installer.install { success in
            guard success else { return }
            // 백그라운드 프로그램이 올라올 시간을 조금 준다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                model.refreshConfig()
            }
        }
    }
}
