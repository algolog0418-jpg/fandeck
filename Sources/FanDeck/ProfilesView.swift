//  ProfilesView.swift — 프로파일 관리와 자동 전환 규칙
//
//  원본에는 "사전 설정" 개념만 있고 자동 전환이 없다. 여기서는 특정 앱을 켜면
//  (예: 영상 편집, 게임) 자동으로 성능 프로파일로 넘어가게 할 수 있다.

import SwiftUI

private final class ProfilesState: ObservableObject {
    @Published var editingProfileID: UUID?
    @Published var newAppName: String = ""
}

struct ProfilesView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = ProfilesState()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gridSpacing) {
                autoSwitchCard
                ForEach(model.config?.profiles ?? []) { profile in
                    profileCard(profile)
                }
                addButton
            }
            .padding(Theme.gridSpacing)
        }
    }

    private var autoSwitchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.config?.autoSwitchEnabled ?? false },
                set: { newValue in
                    guard var c = model.config else { return }
                    c.autoSwitchEnabled = newValue
                    model.apply(config: c)
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("자동 프로파일 전환", "Automatic profile switching")).font(.system(size: 13, weight: .semibold))
                    Text(L.t("조건을 만족하는 프로파일로 알아서 바꿉니다. 조건이 없으면 그대로 둡니다.", "Switches to a profile whose condition matches. Does nothing if none are set."))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if (model.config?.autoSwitchEnabled ?? false), hasAnyTrigger {
                Text(L.t("여러 조건이 동시에 맞으면 온도 기준이 가장 높은 프로파일이 쓰입니다. 앱 조건은 온도 조건보다 먼저입니다.",
                         "When several conditions match, the profile with the highest temperature threshold wins. App conditions take precedence over temperature ones."))
                    .font(Theme.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reason = model.snapshot?.autoSwitchReason {
                StatusBadge(text: L.t("자동 전환 중 · ", "Auto-switched · ") + reason,
                            color: .accentColor, symbol: "wand.and.stars")
            }

            // 조건만 걸어 두고 이 스위치를 켜지 않으면 아무 일도 일어나지 않는다.
            // 사용자가 "왜 안 바뀌지" 하고 헤매기 쉬운 지점이라 분명히 알려 준다.
            if !(model.config?.autoSwitchEnabled ?? false), hasAnyTrigger {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Text(L.t("조건을 정해 두었지만 자동 전환이 꺼져 있어 적용되지 않습니다.",
                             "Conditions are set, but automatic switching is off, so they do nothing."))
                        .font(Theme.caption)
                    Spacer()
                    Button(L.t("켜기", "Turn on")) {
                        guard var c = model.config else { return }
                        c.autoSwitchEnabled = true
                        model.apply(config: c)
                    }
                    .controlSize(.small)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
        .card()
    }

    /// 전환 조건이 하나라도 걸려 있는지.
    private var hasAnyTrigger: Bool {
        (model.config?.profiles ?? []).contains {
            if case .manual = $0.trigger { return false }
            return true
        }
    }

    private func profileCard(_ profile: Profile) -> some View {
        let isActive = profile.id == model.config?.activeProfileID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isActive ? Color.accentColor.opacity(0.15)
                                                       : Color.primary.opacity(0.06)))

                if ui.editingProfileID == profile.id {
                    TextField(L.t("이름", "Name"), text: Binding(
                        get: { profile.name },
                        set: { rename(profile, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { ui.editingProfileID = nil }
                } else {
                    Text(profile.displayName).font(.system(size: 13, weight: .semibold))
                }

                if profile.isBuiltIn {
                    Text(L.t("내장", "Built-in")).font(Theme.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                Spacer()

                if isActive {
                    StatusBadge(text: L.t("사용 중", "Active"), color: .green)
                } else {
                    Button(L.t("적용", "Apply")) { model.activate(profile: profile) }
                        .controlSize(.small)
                        .disabled(!model.daemonAvailable)
                }

                Menu {
                    Button(L.t("이름 바꾸기", "Rename")) { ui.editingProfileID = profile.id }
                        .disabled(profile.isBuiltIn)
                    Button(L.t("복제", "Duplicate")) { duplicate(profile) }
                    Divider()
                    Button(L.t("삭제", "Delete"), role: .destructive) { delete(profile) }
                        .disabled(profile.isBuiltIn)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // 팬별 모드 요약
            HStack(spacing: 8) {
                ForEach(profile.fanSettings, id: \.fanIndex) { setting in
                    Text(setting.mode.label)
                        .font(Theme.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
            }

            triggerEditor(profile)
        }
        .card(tint: isActive ? Color.accentColor : nil)
    }

    private func triggerEditor(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(L.t("자동 전환 조건", "Auto-switch condition")).font(Theme.label).foregroundStyle(.secondary)
                Picker("", selection: triggerKind(profile)) {
                    Text(L.t("없음", "None")).tag(0)
                    Text(L.t("앱 실행 시", "App running")).tag(1)
                    Text(L.t("온도 초과 시", "Above temperature")).tag(2)
                }
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.small)
                Spacer()
            }

            switch profile.trigger {
            case .manual:
                EmptyView()

            case .appRunning(let names):
                HStack(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 3) {
                            Text(name).font(Theme.caption)
                            Button {
                                setTrigger(profile, .appRunning(names: names.filter { $0 != name }))
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                    TextField(L.t("프로세스 이름 (예: Final Cut Pro)", "Process name (e.g. Final Cut Pro)"), text: $ui.newAppName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 190)
                        .onSubmit {
                            let trimmed = ui.newAppName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            setTrigger(profile, .appRunning(names: names + [trimmed]))
                            ui.newAppName = ""
                        }
                    Spacer()
                }

            case .sensorAbove(let key, let value):
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { key },
                        set: { setTrigger(profile, .sensorAbove(key: $0, value: value)) })) {
                        ForEach(model.descriptors.filter { $0.isSynthetic && $0.unit == .celsius }, id: \.key) { d in
                            Text(d.displayName).tag(d.key)
                        }
                    }
                    .labelsHidden().frame(width: 170).controlSize(.small)

                    Stepper(value: Binding(
                        get: { value },
                        set: { setTrigger(profile, .sensorAbove(key: key, value: $0)) }),
                            in: 40...100, step: 1) {
                        Text("\(Int(value))°C 초과").font(Theme.numeric(11))
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private func triggerKind(_ profile: Profile) -> Binding<Int> {
        Binding(
            get: {
                switch profile.trigger {
                case .manual: return 0
                case .appRunning: return 1
                case .sensorAbove: return 2
                }
            },
            set: { kind in
                switch kind {
                case 1: setTrigger(profile, .appRunning(names: []))
                case 2: setTrigger(profile, .sensorAbove(key: SensorCatalog.cpuMaxKey, value: 80))
                default: setTrigger(profile, .manual)
                }
            })
    }

    private var addButton: some View {
        Button {
            guard var config = model.config else { return }
            let fans = model.fans.map(\.index)
            let new = Profile(name: L.t("새 프로파일", "New profile"), symbol: "slider.horizontal.3",
                              fanSettings: (fans.isEmpty ? [0] : fans).map {
                                  FanSetting(fanIndex: $0, mode: .automatic)
                              })
            config.profiles.append(new)
            model.apply(config: config)
        } label: {
            Label(L.t("프로파일 추가", "Add profile"), systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.secondary.opacity(0.35))
        }
    }

    // MARK: 변경 적용

    private func mutate(_ profile: Profile, _ body: (inout Profile) -> Void) {
        guard var config = model.config,
              let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var copy = config.profiles[index]
        body(&copy)
        config.profiles[index] = copy
        model.apply(config: config)
    }

    private func setTrigger(_ profile: Profile, _ trigger: ProfileTrigger) {
        guard var config = model.config,
              let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        config.profiles[index].trigger = trigger

        // 조건을 처음 거는 순간 자동 전환도 같이 켠다.
        // 조건만 정해 두고 스위치를 켜지 않아 "안 되는데요" 가 되는 걸 막는다.
        if case .manual = trigger {} else if !config.autoSwitchEnabled {
            config.autoSwitchEnabled = true
        }
        model.apply(config: config)
    }

    private func rename(_ profile: Profile, to name: String) {
        mutate(profile) { $0.name = name }
    }

    private func duplicate(_ profile: Profile) {
        guard var config = model.config else { return }
        var copy = profile
        copy.id = UUID()
        copy.name = profile.displayName + L.t(" 사본", " copy")
        copy.isBuiltIn = false
        config.profiles.append(copy)
        model.apply(config: config)
    }

    private func delete(_ profile: Profile) {
        guard var config = model.config, !profile.isBuiltIn else { return }
        config.profiles.removeAll { $0.id == profile.id }
        // 지금 쓰고 있는 프로파일을 지웠으면 첫 번째로 되돌린다.
        if config.activeProfileID == profile.id, let first = config.profiles.first {
            config.activeProfileID = first.id
        }
        model.apply(config: config)
    }
}
