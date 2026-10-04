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
                    Text("팬 제어 켜기").font(.system(size: 12, weight: .medium))
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
        case .installing: return "켜는 중입니다"
        case .failed:     return "켜지 못했습니다"
        default:          return "팬 제어가 아직 꺼져 있습니다"
        }
    }

    private var message: String {
        switch installer.state {
        case .installing:
            return "잠시만 기다려 주세요."
        case .failed(let reason):
            return reason
        default:
            if installer.canInstall {
                return "켜면 팬 속도를 직접 정할 수 있습니다. macOS 암호 창이 한 번 뜹니다. 온도 보기는 켜지 않아도 됩니다."
            }
            return "앱을 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요."
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
