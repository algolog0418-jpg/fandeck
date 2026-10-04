//  SettingsView.swift — 설정
//
//  항목이 늘어나면서 한 줄로 늘어놓으면 찾기 어려워졌다.
//  성격별로 탭을 나눈다: 일반 / 센서 / 메뉴 막대 / 팬 제어.

import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

private final class SettingsState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case general, sensors, menuBar, control
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "일반"
            case .sensors: return "센서"
            case .menuBar: return "메뉴 막대"
            case .control: return "팬 제어"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .sensors: return "thermometer.medium"
            case .menuBar: return "menubar.rectangle"
            case .control: return "fan"
            }
        }
    }

    @Published var section: Section = .general
    @Published var exportMessage: String?
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = SettingsState()
    @StateObject private var updater = UpdateChecker.shared
    @StateObject private var installer = HelperInstaller.shared

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            Divider()
            ScrollView {
                VStack(spacing: Theme.gridSpacing) {
                    switch ui.section {
                    case .general: generalSection
                    case .sensors: sensorSection
                    case .menuBar: menuBarSection
                    case .control: controlSection
                    }
                }
                .padding(Theme.gridSpacing)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(SettingsState.Section.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { ui.section = section }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.symbol).font(.system(size: 15))
                        Text(section.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 84, height: 48)
                    .background {
                        if ui.section == section {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                        }
                    }
                    .foregroundStyle(ui.section == section ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.gridSpacing)
        .padding(.vertical, 8)
    }

    // MARK: - 일반

    private var generalSection: some View {
        VStack(spacing: Theme.gridSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "시작")

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
                    Text("로그인할 때 자동으로 실행").font(.system(size: 12))
                }
                .toggleStyle(.switch)

                Toggle(isOn: configBinding(\.startMinimized)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("창을 띄우지 않고 메뉴 막대로만 시작").font(.system(size: 12))
                        Text("자동 실행될 때 화면을 가리지 않습니다.")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(SMAppService.mainApp.status != .enabled)

                Toggle(isOn: configBinding(\.checkUpdatesOnLaunch)) {
                    Text("시작할 때 새 버전 확인").font(.system(size: 12))
                }
                .toggleStyle(.switch)
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "표시")

                Toggle(isOn: configBinding(\.showDockIcon)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dock 에 아이콘 표시").font(.system(size: 12))
                        Text("끄면 창을 닫았을 때 Dock 에서 사라지고 메뉴 막대에만 남습니다.")
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

            versionCard
        }
    }

    private var versionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "fan.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("FanDeck \(updater.currentVersion)").font(.system(size: 13, weight: .semibold))
                switch updater.state {
                case .checking:
                    Text("확인 중…").font(Theme.caption).foregroundStyle(.secondary)
                case .upToDate:
                    Text("최신 버전입니다").font(Theme.caption).foregroundStyle(.secondary)
                case .available(let version, _):
                    Text("새 버전 \(version) 이 있습니다").font(Theme.caption).foregroundStyle(.orange)
                case .failed(let message):
                    Text(message).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                case .idle:
                    Text("센서 \(model.descriptors.count)개 · 팬 \(model.fans.count)개 인식됨")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .available(_, let url) = updater.state {
                Button("받으러 가기") {
                    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("지금 확인") { updater.check() }
                    .disabled(updater.state == .checking)
            }
        }
        .card()
    }

    // MARK: - 센서

    private var sensorSection: some View {
        VStack(spacing: Theme.gridSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "온도 표시")

                HStack(spacing: 12) {
                    Text("단위").font(.system(size: 12)).frame(width: 60, alignment: .leading)
                    Picker("", selection: configBinding(\.temperatureUnit)) {
                        ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                            Text(unit.localizedName).tag(unit)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    Spacer()
                }

                Toggle(isOn: configBinding(\.showDecimals)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("온도를 정확하게 표시").font(.system(size: 12))
                        Text(exampleTemperature).font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "저장장치 온도")

                Text("내장 SSD 온도는 기본으로 읽습니다(센서 목록의 '저장장치' 그룹).")
                    .font(Theme.caption).foregroundStyle(.secondary)

                Toggle(isOn: configBinding(\.includeExternalDrives)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("외장 드라이브 온도 포함 (USB·Thunderbolt)").font(.system(size: 12))
                        if !DriveTemperature.isAvailable {
                            Text("외장 드라이브는 드라이브 자체의 S.M.A.R.T. 정보를 읽어야 해서 smartmontools 가 필요합니다. 터미널에서 brew install smartmontools 로 설치하면 켤 수 있습니다.")
                                .font(Theme.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.switch)
                .disabled(!DriveTemperature.isAvailable)
            }
            .card()

            notificationCard
            safetyCard
        }
    }

    private var exampleTemperature: String {
        let sample = 45.4
        let unit = model.config?.temperatureUnit ?? .celsius
        let on = ValueFormat(temperatureUnit: unit, showDecimals: true).string(sample, unit: .celsius)
        let off = ValueFormat(temperatureUnit: unit, showDecimals: false).string(sample, unit: .celsius)
        return "켜면 \(on), 끄면 \(off) 처럼 보입니다"
    }

    // MARK: - 메뉴 막대

    private var menuBarSection: some View {
        VStack(spacing: Theme.gridSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "메뉴 막대", subtitle: "현재 표시: \(model.menuBarTitle.replacingOccurrences(of: "\n", with: " / "))")

                row("아이콘") {
                    Picker("", selection: configBinding(\.menuBarIconStyle)) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }

                row("팬") {
                    Picker("", selection: Binding(
                        get: { model.config?.menuBarFanIndex ?? -1 },
                        set: { newValue in
                            guard var c = model.config else { return }
                            c.menuBarFanIndex = newValue < 0 ? nil : newValue
                            c.menuBarShowsFan = newValue != -2
                            model.apply(config: c)
                        })) {
                        Text("표시 안 함").tag(-2)
                        Text("첫 번째 팬").tag(-1)
                        ForEach(model.fans) { fan in
                            Text(fan.name).tag(fan.index)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }

                row("센서") {
                    Picker("", selection: Binding(
                        get: { model.config?.menuBarShowsTemperature == false
                               ? "" : (model.config?.menuBarSensorKey ?? SensorCatalog.cpuMaxKey) },
                        set: { newKey in
                            guard var c = model.config else { return }
                            if newKey.isEmpty { c.menuBarShowsTemperature = false }
                            else {
                                c.menuBarShowsTemperature = true
                                c.menuBarSensorKey = newKey
                            }
                            model.apply(config: c)
                        })) {
                        Text("표시 안 함").tag("")
                        ForEach(model.descriptors.filter { $0.unit == .celsius && $0.isSynthetic }, id: \.key) { d in
                            Text(d.name).tag(d.key)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }

                Divider()

                Toggle(isOn: configBinding(\.menuBarTwoLines)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("팬과 센서를 두 줄로 표시").font(.system(size: 12))
                        Text("메뉴 막대 가로 공간을 아낍니다.")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .card()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12)).frame(width: 60, alignment: .leading)
            content()
            Spacer()
        }
    }

    // MARK: - 팬 제어

    private var controlSection: some View {
        VStack(spacing: Theme.gridSpacing) {
            daemonCard
            safetyCard
            dataCard
        }
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
                    labeledStepper("임계 온도", value: safetyBinding(\.criticalTemperature), range: 70...105)
                    labeledStepper("해제 온도", value: safetyBinding(\.recoveryTemperature), range: 50...100)
                    Spacer()
                }
                Text("해제 온도는 임계 온도보다 낮게 두세요. 두 값이 가까우면 팬이 켜졌다 꺼졌다를 반복합니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)

                if let key = model.config?.safety.sensorKey, let now = model.reading(key) {
                    HStack(spacing: 6) {
                        Text("현재").font(Theme.caption).foregroundStyle(.secondary)
                        Text(model.display(now, unit: .celsius))
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

    /// 임계·해제 온도는 섭씨로 저장하고, 화씨 설정이면 보일 때만 바꿔 준다.
    private func labeledStepper(_ title: String, value: Binding<Double>,
                                range: ClosedRange<Double>) -> some View {
        let unit = model.config?.temperatureUnit ?? .celsius
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.label).foregroundStyle(.secondary)
            Stepper(value: value, in: range, step: 1) {
                Text("\(Int(unit.convert(value.wrappedValue).rounded()))\(unit.suffix)")
                    .font(Theme.numeric(13))
            }
            .frame(width: 130)
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
                let unit = model.config?.temperatureUnit ?? .celsius
                Stepper(value: Binding(
                    get: { threshold },
                    set: { newValue in
                        guard var c = model.config else { return }
                        c.notifyAboveTemperature = newValue
                        model.apply(config: c)
                    }), in: 50...105, step: 1) {
                    Text("기준 \(Int(unit.convert(threshold).rounded()))\(unit.suffix)")
                        .font(Theme.numeric(12))
                }
                .frame(width: 170)
                Text("한 번 알린 뒤에는 기준보다 5°C 아래로 내려갔다 다시 올라올 때까지 울리지 않습니다.")
                    .font(Theme.caption).foregroundStyle(.tertiary)
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

    // MARK: 기록

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

    // MARK: 팬 제어 상태

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
                        installer.uninstall { _ in model.refreshConfig() }
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
}
