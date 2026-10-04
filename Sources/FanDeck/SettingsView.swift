//  SettingsView.swift — 안전장치, 메뉴바, 데몬 상태

import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

private final class SettingsState: ObservableObject {
    @Published var exportMessage: String?
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = SettingsState()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gridSpacing) {
                generalCard
                safetyCard
                notificationCard
                menuBarCard
                dataCard
                daemonCard
                aboutCard
            }
            .padding(Theme.gridSpacing)
        }
    }

    // MARK: 일반

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "일반")

            Toggle(isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        ui.exportMessage = "로그인 항목을 바꾸지 못했습니다: \(error.localizedDescription)"
                    }
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("로그인할 때 자동으로 실행").font(.system(size: 12))
                    Text("메뉴 막대에 온도가 바로 뜹니다. 팬 제어 자체는 앱을 켜지 않아도 유지됩니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("화면 갱신 주기").font(.system(size: 12))
                    Text("짧을수록 수치가 자주 바뀌지만 그만큼 CPU 를 씁니다. 창을 닫아 두면 자동으로 느려집니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { model.refreshInterval },
                    set: { model.refreshInterval = $0 })) {
                    Text("1초").tag(1.0)
                    Text("1.5초").tag(1.5)
                    Text("2초").tag(2.0)
                    Text("3초").tag(3.0)
                }
                .labelsHidden().frame(width: 190).pickerStyle(.segmented)
            }
        }
        .card()
    }

    // MARK: 과열 보호

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "과열 보호",
                          subtitle: "어떤 설정이든 이 규칙이 가장 먼저 적용됩니다")

            Toggle(isOn: safetyBinding(\.enabled)) {
                Text("임계 온도를 넘으면 팬을 최대로 돌리기").font(.system(size: 12))
            }
            .toggleStyle(.switch)

            if model.config?.safety.enabled ?? true {
                HStack(spacing: 12) {
                    Text("기준 센서").font(Theme.label).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.config?.safety.sensorKey ?? SensorCatalog.systemMaxKey },
                        set: { newKey in
                            guard var c = model.config else { return }
                            c.safety.sensorKey = newKey
                            model.apply(config: c)
                        })) {
                        ForEach(model.descriptors.filter { $0.isSynthetic && $0.unit == .celsius }, id: \.key) { d in
                            Text(d.name).tag(d.key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                }

                HStack(spacing: 20) {
                    labeledStepper("임계 온도", value: safetyBinding(\.criticalTemperature),
                                   range: 70...105, suffix: "°C")
                    labeledStepper("해제 온도", value: safetyBinding(\.recoveryTemperature),
                                   range: 50...100, suffix: "°C")
                    Spacer()
                }
                Text("해제 온도는 임계 온도보다 낮게 두세요. 두 값이 가까우면 팬이 켜졌다 꺼졌다를 반복합니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)

                if let key = model.config?.safety.sensorKey, let now = model.reading(key) {
                    HStack(spacing: 6) {
                        Text("현재").font(Theme.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.1f°C", now))
                            .font(Theme.numeric(12))
                            .foregroundStyle(Theme.temperatureColor(now))
                    }
                }
            }
        }
        .card()
    }

    private func safetyBinding<V>(_ keyPath: WritableKeyPath<SafetySettings, V>) -> Binding<V> {
        Binding(
            get: { model.config?.safety[keyPath: keyPath] ?? SafetySettings()[keyPath: keyPath] },
            set: { newValue in
                guard var c = model.config else { return }
                c.safety[keyPath: keyPath] = newValue
                model.apply(config: c)
            })
    }

    private func labeledStepper(_ title: String, value: Binding<Double>,
                                range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.label).foregroundStyle(.secondary)
            Stepper(value: value, in: range, step: 1) {
                Text("\(Int(value.wrappedValue))\(suffix)").font(Theme.numeric(13))
            }
            .frame(width: 110)
        }
    }

    // MARK: 알림

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "알림",
                          subtitle: "메뉴 막대에 표시 중인 센서를 기준으로 알립니다")

            Toggle(isOn: Binding(
                get: { model.config?.notifyAboveTemperature != nil },
                set: { enabled in
                    guard var c = model.config else { return }
                    c.notifyAboveTemperature = enabled ? 85 : nil
                    model.apply(config: c)
                })) {
                Text("온도가 기준을 넘으면 알림 보내기").font(.system(size: 12))
            }
            .toggleStyle(.switch)

            if let threshold = model.config?.notifyAboveTemperature {
                Stepper(value: Binding(
                    get: { threshold },
                    set: { newValue in
                        guard var c = model.config else { return }
                        c.notifyAboveTemperature = newValue
                        model.apply(config: c)
                    }), in: 50...105, step: 1) {
                    Text("기준 \(Int(threshold))°C").font(Theme.numeric(12))
                }
                .frame(width: 150)
                Text("한 번 알린 뒤에는 기준보다 5°C 아래로 내려갔다 다시 올라올 때까지 울리지 않습니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    // MARK: 메뉴바

    private var menuBarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "메뉴 막대", subtitle: "현재 표시: \(model.menuBarTitle)")

            Toggle("팬 속도 표시", isOn: configBinding(\.menuBarShowsFan)).toggleStyle(.switch)
            Toggle("온도 표시", isOn: configBinding(\.menuBarShowsTemperature)).toggleStyle(.switch)

            HStack(spacing: 12) {
                Text("표시할 센서").font(Theme.label).foregroundStyle(.secondary)
                Picker("", selection: configBinding(\.menuBarSensorKey)) {
                    ForEach(model.descriptors.filter { $0.unit == .celsius && $0.isSynthetic }, id: \.key) { d in
                        Text(d.name).tag(d.key)
                    }
                }
                .labelsHidden().frame(width: 200)
                Spacer()
            }
        }
        .card()
    }

    private func configBinding<V>(_ keyPath: WritableKeyPath<FanDeckConfig, V>) -> Binding<V> {
        Binding(
            get: {
                model.config?[keyPath: keyPath]
                    ?? FanDeckConfig.makeDefault(fans: [])[keyPath: keyPath]
            },
            set: { newValue in
                guard var c = model.config else { return }
                c[keyPath: keyPath] = newValue
                model.apply(config: c)
            })
    }

    // MARK: 기록 내보내기

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "기록",
                          subtitle: "백그라운드에서 쌓아 둔 온도·팬 속도 기록입니다")

            HStack(spacing: 10) {
                Button {
                    exportCSV()
                } label: {
                    Label("CSV 로 내보내기", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.daemonAvailable)

                if let message = ui.exportMessage {
                    Text(message).font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !model.daemonAvailable {
                Text("팬 제어가 꺼져 있으면 앱이 켜져 있는 동안의 기록만 남습니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "fandeck-\(formatter.string(from: Date())).csv"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached(priority: .userInitiated) {
            guard case .history(let samples)? = try? IPCClient.send(.history(sinceSeconds: 6 * 3600,
                                                                            maxCount: 100_000),
                                                                    timeout: 10) else {
                await MainActor.run { ui.exportMessage = "기록을 가져오지 못했습니다" }
                return
            }
            let keys = Array(Set(samples.flatMap { $0.values.keys })).sorted()
            let fanIndices = Array(Set(samples.flatMap { $0.fanRPM.keys })).sorted()
            let names = await MainActor.run { keys.map { model.descriptor($0)?.name ?? $0 } }

            var csv = "시각," + names.joined(separator: ",")
            if !fanIndices.isEmpty { csv += "," + fanIndices.map { "팬\($0) RPM" }.joined(separator: ",") }
            csv += "\n"

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for s in samples {
                var row = [df.string(from: s.date)]
                row += keys.map { s.values[$0].map { String(format: "%.2f", $0) } ?? "" }
                row += fanIndices.map { s.fanRPM[$0].map { String(format: "%.0f", $0) } ?? "" }
                csv += row.joined(separator: ",") + "\n"
            }

            // 엑셀에서 한글이 깨지지 않도록 BOM 을 붙인다.
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(csv.utf8))
            let ok = (try? data.write(to: url)) != nil
            await MainActor.run {
                ui.exportMessage = ok ? "\(samples.count)개 표본을 저장했습니다" : "저장하지 못했습니다"
            }
        }
    }

    // MARK: 데몬

    private var daemonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "팬 제어",
                          subtitle: "팬 속도를 바꾸려면 macOS 가 관리자 권한을 요구합니다")

            HStack(spacing: 10) {
                if model.daemonAvailable {
                    StatusBadge(text: "켜짐", color: .green, symbol: "checkmark.seal.fill")
                    if model.snapshot?.smcWritable == true {
                        StatusBadge(text: "팬 제어 정상", color: .green)
                    } else {
                        StatusBadge(text: "속도 변경이 반영되지 않음", color: .orange,
                                    symbol: "exclamationmark.triangle.fill")
                    }
                    if let uptime = model.snapshot?.uptimeSeconds {
                        Text("\(formatUptime(uptime))째 동작 중")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                } else {
                    StatusBadge(text: "꺼짐", color: .orange)
                }
                Spacer()
            }

            if model.daemonAvailable {
                HStack(spacing: 8) {
                    Button("모든 팬을 자동으로 되돌리기") { model.releaseAll() }
                    Button("팬 제어 끄기") {
                        HelperInstaller.shared.uninstall { _ in model.refreshConfig() }
                    }
                    Spacer()
                }
                Text("끄면 팬은 macOS 가 다시 알아서 관리합니다. 설정한 프로파일은 그대로 남습니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)
            } else {
                EnableControlBanner(model: model)
            }

            if let error = model.lastError {
                Text(error).font(Theme.caption).foregroundStyle(.orange)
            }
        }
        .card()
    }

    private func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)시간 \(m)분" }
        return "\(m)분"
    }

    private var aboutCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "fan.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("FanDeck 1.0.0").font(.system(size: 13, weight: .semibold))
                Text("센서 \(model.descriptors.count)개 · 팬 \(model.fans.count)개 인식됨")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card()
    }
}
