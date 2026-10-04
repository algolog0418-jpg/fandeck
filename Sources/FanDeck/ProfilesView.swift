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
                    Text("자동 프로파일 전환").font(.system(size: 13, weight: .semibold))
                    Text("조건을 만족하는 프로파일로 데몬이 알아서 바꿉니다. 조건이 없으면 그대로 둡니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let reason = model.snapshot?.autoSwitchReason {
                StatusBadge(text: "자동 전환 중 · \(reason)", color: .accentColor, symbol: "wand.and.stars")
            }
        }
        .card()
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
                    TextField("이름", text: Binding(
                        get: { profile.name },
                        set: { rename(profile, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { ui.editingProfileID = nil }
                } else {
                    Text(profile.name).font(.system(size: 13, weight: .semibold))
                }

                if profile.isBuiltIn {
                    Text("내장").font(Theme.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                Spacer()

                if isActive {
                    StatusBadge(text: "사용 중", color: .green)
                } else {
                    Button("적용") { model.activate(profile: profile) }
                        .controlSize(.small)
                        .disabled(!model.daemonAvailable)
                }

                Menu {
                    Button("이름 바꾸기") { ui.editingProfileID = profile.id }
                        .disabled(profile.isBuiltIn)
                    Button("복제") { duplicate(profile) }
                    Divider()
                    Button("삭제", role: .destructive) { delete(profile) }
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
                Text("자동 전환 조건").font(Theme.label).foregroundStyle(.secondary)
                Picker("", selection: triggerKind(profile)) {
                    Text("없음").tag(0)
                    Text("앱 실행 시").tag(1)
                    Text("온도 초과 시").tag(2)
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
                    TextField("프로세스 이름 (예: Final Cut Pro)", text: $ui.newAppName)
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
                            Text(d.name).tag(d.key)
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
            let new = Profile(name: "새 프로파일", symbol: "slider.horizontal.3",
                              fanSettings: (fans.isEmpty ? [0] : fans).map {
                                  FanSetting(fanIndex: $0, mode: .automatic)
                              })
            config.profiles.append(new)
            model.apply(config: config)
        } label: {
            Label("프로파일 추가", systemImage: "plus.circle.fill")
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
        mutate(profile) { $0.trigger = trigger }
    }

    private func rename(_ profile: Profile, to name: String) {
        mutate(profile) { $0.name = name }
    }

    private func duplicate(_ profile: Profile) {
        guard var config = model.config else { return }
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " 사본"
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
