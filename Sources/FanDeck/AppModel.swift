//  AppModel.swift — 앱 전역 상태
//
//  센서 읽기는 권한이 필요 없으므로 앱이 직접 SMC 에서 읽는다(데몬을 거치면 지연만 는다).
//  반대로 팬에 값을 쓰는 일은 전부 데몬에 요청한다.

import SwiftUI
import AppKit
import Observation

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    // MARK: 읽기 상태
    private(set) var descriptors: [SensorDescriptor] = []
    private(set) var readings: [String: Double] = [:]
    private(set) var fans: [FanInfo] = []
    private(set) var snapshot: StatusSnapshot?
    private(set) var daemonAvailable = false
    /// 백그라운드 서비스가 앱과 다른 버전인지.
    ///
    /// 서비스는 설정 파일을 자기가 아는 구조로만 읽고 쓴다. 앱만 새로 올리면
    /// 새로 생긴 설정 항목을 서비스가 통째로 버려서, 사용자가 뭘 바꿔도
    /// 되돌아가는 것처럼 보인다.
    ///
    /// 버전 문자열(1.0.0)은 빌드마다 바뀌지 않고, 바이너리 크기는 관계없는 변경에도
    /// 달라진다. 설정 구조의 판 번호를 비교하는 게 정확하다.
    private(set) var helperOutdated = false

    /// 현재 언어.
    ///
    /// `L.language` 는 전역 변수라 바뀌어도 SwiftUI 가 알지 못한다.
    /// 화면이 다시 그려지도록 관찰 가능한 속성으로도 들고 있는다.
    private(set) var language: AppLanguage = .system
    /// 마지막으로 반영한 설정 개정 번호.
    @ObservationIgnored private var lastConfigRevision = -1

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
    private(set) var lastError: String?

    // MARK: 시스템 사용량
    private(set) var cpuUsage = CPUUsage(user: 0, system: 0, idle: 100)
    private(set) var memoryUsage = MemoryUsage(total: 0, used: 0, wired: 0,
                                               compressed: 0, cached: 0, pressure: 0)
    private(set) var processes: [ProcessEntry] = []
    /// ps 를 매초 부르면 그 자체가 CPU 를 쓴다. 프로세스 탭을 보고 있을 때만 자주 읽는다.
    var needsProcessList = false
    private var processTickCounter = 0

    /// 그래프 구간(분). 뷰가 아니라 모델이 들고 있어야 파생 데이터를 미리 계산할 수 있다.
    var chartMinutes: Double = 5 {
        didSet { recomputeDerived() }
    }

    // 뷰가 매 렌더마다 다시 계산하면 안 되는 파생 데이터.
    //
    // 값이 매초 바뀌는 화면이라 SwiftUI 가 뷰 트리를 통째로 다시 평가하는데,
    // 그때마다 통계(기록 전체 순회)와 그래프 시리즈를 다시 만들면
    // 같은 계산을 초당 수십 번 반복하게 된다. 틱당 한 번만 만들어 두고 뷰는 읽기만 한다.
    private(set) var series: [String: [(Date, Double)]] = [:]
    private(set) var fanSeries: [Int: [(Date, Double)]] = [:]
    private(set) var statistics: [String: SensorStatistics] = [:]
    /// 대시보드 상단에 띄울 센서 키. 즐겨찾기가 바뀔 때만 다시 고른다.
    private(set) var highlightKeys: [String] = []

    /// 앱이 켜져 있는 동안의 짧은 히스토리. 긴 추이는 제어 서비스에서 받아온다.
    private(set) var liveHistory: [HistorySample] = []
    /// 표본 개수가 아니라 "몇 분치" 로 잡는다. 갱신 주기를 바꾸면 개수도 따라가야
    /// 그래프가 항상 같은 시간 범위를 보여준다.
    private var liveHistoryLimit: Int {
        max(Int(20 * 60 / max(refreshInterval, 0.5)), 200)
    }

    // MARK: 설정
    var config: FanDeckConfig?

    // MARK: UI 상태
    var selectedTab: Tab = .dashboard
    /// 자동 설치 안내를 이미 띄웠는지. 취소한 사람에게 매번 들이밀지 않는다.
    private let autoPromptKey = "FanDeck.didPromptForControl"
    var sensorSearch: String = ""
    var selectedFanIndex: Int = 0
    /// 전체 센서를 매 틱 읽으면 IOKit 호출이 과해서, 센서 탭이 열렸을 때만 전부 읽는다.
    var needsAllSensors = false

    enum Tab: String, CaseIterable, Identifiable {
        case dashboard, sensors, activity, curve, profiles, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: return L.t("대시보드", "Dashboard")
            case .sensors:   return L.t("센서", "Sensors")
            case .activity:  return L.t("활동", "Activity")
            case .curve:     return L.t("팬 커브", "Fan Curve")
            case .profiles:  return L.t("프로파일", "Profiles")
            case .settings:  return L.t("설정", "Settings")
            }
        }

        var symbol: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .sensors:   return "thermometer.variable"
            case .activity:  return "chart.bar.xaxis"
            case .curve:     return "chart.xyaxis.line"
            case .profiles:  return "square.stack.3d.up"
            case .settings:  return "gearshape"
            }
        }
    }

    private var timer: Timer?
    private let smc = SMCService.shared
    private var descriptorsByKey: [String: SensorDescriptor] = [:]

    private init() {
        loadDescriptors()
        refreshConfig()
        NotificationManager.shared.requestAuthorizationIfNeeded()
        startPolling()
        scheduleAutoEnable()
    }

    // MARK: 초기화

    private func loadDescriptors() {
        do {
            try smc.open()
            let keys = Set(try smc.allKeys())
            descriptors = SensorCatalog.build(availableKeys: keys)
            descriptorsByKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
        } catch {
            lastError = "\(error)"
        }
    }

    /// 처음 실행이고 팬 제어가 꺼져 있으면, 사용자가 버튼을 찾아 헤매지 않도록
    /// 앱이 뜨자마자 알아서 권한 창을 띄운다. 한 번 거절하면 다시 띄우지 않는다.
    private func scheduleAutoEnable() {
        guard !UserDefaults.standard.bool(forKey: autoPromptKey) else { return }
        guard HelperInstaller.shared.canInstall else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.daemonAvailable else { return }
            UserDefaults.standard.set(true, forKey: self.autoPromptKey)
            HelperInstaller.shared.install { success in
                guard success else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.refreshConfig()
                }
            }
        }
    }

    // MARK: 폴링

    /// 화면 갱신 주기(초). 짧을수록 반응이 빠르지만, 매 갱신마다 SwiftUI 가
    /// 뷰 트리 레이아웃을 다시 계산하므로 그만큼 CPU 를 쓴다.
    var refreshInterval: Double = 1.5

    /// 창이 열려 보이는지. 메뉴 막대 앱이라 평소에는 창이 닫혀 있는데,
    /// 그때도 전부 갱신하면 아무도 안 보는 화면을 그리느라 CPU 를 쓴다.
    var isWindowVisible = false
    /// 메뉴 막대 팝오버가 열려 있는지.
    var isMenuOpen = false

    private var isUIVisible: Bool { isWindowVisible || isMenuOpen }

    /// 아무 화면도 안 보이면 메뉴 막대 글자에 필요한 값만, 느리게 읽는다.
    private var effectiveInterval: Double {
        isUIVisible ? refreshInterval : 5.0
    }

    /// 타이머는 짧은 고정 주기로 돌리고, 실제 갱신 여부는 안에서 판단한다.
    /// 주기가 바뀔 때마다 타이머를 다시 걸면, 그 과정이 갱신을 다시 부르면서
    /// 무한 재귀에 빠진다(실제로 그렇게 크래시했다).
    private static let tickResolution: Double = 0.5
    private var accumulated: Double = 0

    func startPolling() {
        timer?.invalidate()
        accumulated = .greatestFiniteMagnitude   // 첫 갱신은 바로
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickResolution, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStep() }
        }
    }

    private func pollStep() {
        refreshWindowVisibility()
        accumulated += Self.tickResolution
        guard accumulated >= effectiveInterval else { return }
        accumulated = 0
        tick()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// 매 틱 읽을 센서를 고른다. 전부 읽으면 IOKit 호출이 350번을 넘는다.
    private func activeKeys() -> [SensorDescriptor] {
        // 화면이 안 보이면 메뉴 막대에 쓰는 센서 하나면 충분하다.
        guard isUIVisible else {
            let key = config?.menuBarSensorKey ?? SensorCatalog.cpuMaxKey
            return descriptors.filter { $0.key == key }
        }
        if needsAllSensors { return descriptors }
        var keys = Set<String>([SensorCatalog.cpuMaxKey, SensorCatalog.cpuAverageKey,
                                SensorCatalog.gpuMaxKey, SensorCatalog.systemMaxKey, "PSTR"])
        if let config {
            keys.formUnion(config.favoriteSensorKeys)
            keys.insert(config.menuBarSensorKey)
            keys.insert(config.safety.sensorKey)
            for profile in config.profiles {
                for setting in profile.fanSettings {
                    if case .curve(let c) = setting.mode { keys.insert(c.sensorKey) }
                }
            }
        }
        return descriptors.filter { keys.contains($0.key) }
    }

    /// 센서 읽기는 IOKit 왕복이라 느리다. 메인 스레드에서 돌리면 UI 가 한 박자씩 밀린다.
    /// 읽기는 전부 백그라운드에서 하고, 완성된 값만 메인으로 넘긴다.
    private func tick() {
        let targets = activeKeys()
        let wantProcesses: Bool = {
            guard isUIVisible else { return false }
            processTickCounter += 1
            let interval = needsProcessList ? 2 : 10
            if processTickCounter >= interval || processes.isEmpty {
                processTickCounter = 0
                return true
            }
            return false
        }()
        let favorites = config?.favoriteSensorKeys ?? []
        // GUI 앱의 표시 이름(카카오톡 등)은 AppKit 에서만 알 수 있다. 메인 스레드에서 미리 모은다.
        var names: [Int32: String] = [:]
        if wantProcesses {
            for app in NSWorkspace.shared.runningApplications {
                if let title = app.localizedName { names[app.processIdentifier] = title }
            }
        }

        Task.detached(priority: .userInitiated) {
            let values = SMCService.shared.snapshot(targets)
            let fanList = FanController.shared.readAllFans()
            let cpu = SystemMonitor.shared.cpuUsage()
            let memory = SystemMonitor.shared.memoryUsage()
            let processList = wantProcesses
                ? SystemMonitor.shared.processes(displayNames: names)
                : nil

            // 히스토리 표본은 백그라운드에서 미리 만들어 둔다.
            var historyValues: [String: Double] = [:]
            for key in [SensorCatalog.cpuMaxKey, SensorCatalog.cpuAverageKey,
                        SensorCatalog.gpuMaxKey, SensorCatalog.systemMaxKey, "PSTR"] + favorites {
                if let v = values[key] { historyValues[key] = v }
            }
            var rpm: [Int: Double] = [:]
            for f in fanList { rpm[f.index] = f.currentRPM }
            let sample = HistorySample(timestamp: Date().timeIntervalSince1970,
                                       values: historyValues, fanRPM: rpm)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.readings.merge(values) { _, new in new }
                self.fans = fanList
                self.cpuUsage = cpu
                self.memoryUsage = memory
                if let processList { self.processes = processList }

                self.liveHistory.append(sample)
                if self.liveHistory.count > self.liveHistoryLimit {
                    self.liveHistory.removeFirst(self.liveHistory.count - self.liveHistoryLimit)
                }

                self.updateMenuBarTitle()
                self.recomputeDerived()
                self.evaluateNotification()
            }
        }

        refreshDaemonStatus()
    }

    private func evaluateNotification() {
        guard let config, let threshold = config.notifyAboveTemperature else { return }
        let key = config.menuBarSensorKey
        NotificationManager.shared.evaluate(temperature: readings[key],
                                            threshold: threshold,
                                            sensorName: descriptor(key)?.name ?? key)
    }

    private func refreshDaemonStatus() {
        // 데몬 통신은 소켓 왕복이라 UI 를 막지 않도록 백그라운드에서 한다.
        Task.detached(priority: .utility) {
            let result = try? IPCClient.send(.status, timeout: 1.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if case .status(let s)? = result {
                    let previouslyUnavailable = !self.daemonAvailable
                    self.snapshot = s
                    self.daemonAvailable = true
                    let outdated = s.configSchema < FanDeckConfig.schemaVersion
                    if outdated != self.helperOutdated { self.helperOutdated = outdated }
                    // 메뉴 막대·CLI·자동 전환 등 다른 쪽에서 설정이 바뀌었을 수 있다.
                    // 개정 번호가 달라졌으면 무엇이 바뀌었든 다시 읽는다.
                    if previouslyUnavailable
                        || s.configRevision != self.lastConfigRevision
                        || self.config?.activeProfileID != s.activeProfileID {
                        self.lastConfigRevision = s.configRevision
                        self.refreshConfig()
                    }
                } else {
                    self.snapshot = nil
                    self.daemonAvailable = false
                    self.helperOutdated = false
                }
            }
        }
    }

    /// 틱마다 한 번, 뷰가 쓸 파생 데이터를 만들어 둔다.
    private func recomputeDerived() {
        guard isUIVisible else { return }
        var keys = config?.favoriteSensorKeys ?? []
        for fallback in [SensorCatalog.cpuMaxKey, SensorCatalog.gpuMaxKey,
                         "PSTR", SensorCatalog.systemMaxKey] where !keys.contains(fallback) {
            keys.append(fallback)
        }
        highlightKeys = Array(keys.filter { descriptorsByKey[$0] != nil }.prefix(6))

        let cutoff = Date().timeIntervalSince1970 - chartMinutes * 60
        // 기록은 시간순이라, 구간 시작점만 찾으면 뒤쪽 전체가 대상이다.
        var startIndex = liveHistory.count
        for (i, sample) in liveHistory.enumerated() where sample.timestamp >= cutoff {
            startIndex = i
            break
        }
        let window = Array(liveHistory[startIndex...])

        var newSeries: [String: [(Date, Double)]] = [:]
        var newStats: [String: SensorStatistics] = [:]
        for key in highlightKeys {
            var points: [(Date, Double)] = []
            points.reserveCapacity(window.count)
            for sample in window {
                if let v = sample.values[key] { points.append((sample.date, v)) }
            }
            newSeries[key] = downsample(points)
            newStats[key] = SensorStatistics.compute(key: key, samples: window)
        }
        series = newSeries
        statistics = newStats

        var newFanSeries: [Int: [(Date, Double)]] = [:]
        for fan in fans {
            var points: [(Date, Double)] = []
            for sample in window {
                if let v = sample.fanRPM[fan.index] { points.append((sample.date, v)) }
            }
            newFanSeries[fan.index] = downsample(points)
        }
        fanSeries = newFanSeries
    }

    // MARK: 값 조회

    func reading(_ key: String) -> Double? { readings[key] }

    /// 온도 단위·소수점 설정. 모든 화면이 이걸 통해 숫자를 만든다.
    var format: ValueFormat { config?.valueFormat ?? .default }

    /// 센서 값을 설정에 맞춰 문자열로. 단위 접미사까지 붙인다.
    func display(_ key: String, includeSuffix: Bool = true) -> String {
        guard let d = descriptorsByKey[key], let v = readings[key] else { return "—" }
        return format.string(v, unit: d.unit, includeSuffix: includeSuffix)
    }

    func display(_ value: Double, unit: SensorUnit, includeSuffix: Bool = true) -> String {
        format.string(value, unit: unit, includeSuffix: includeSuffix)
    }

    func descriptor(_ key: String) -> SensorDescriptor? { descriptorsByKey[key] }

    func formatted(_ key: String) -> String { display(key) }

    /// 지금 쓰는 모드 이름.
    ///
    /// 서비스가 보내 주는 이름은 설정 파일에 저장된 한국어 그대로라서,
    /// 영어로 쓸 때는 앱이 직접 번역해야 한다.
    var activeProfileDisplayName: String {
        if let profile = config?.activeProfile { return profile.displayName }
        return snapshot?.activeProfileName ?? "—"
    }

    /// 팬 하나의 현재 모드 설명. 서비스 문자열 대신 설정에서 다시 만든다.
    func modeLabel(for fanIndex: Int) -> String {
        if snapshot?.isCritical == true { return L.t("과열 보호", "Thermal protection") }
        guard let profile = config?.activeProfile else {
            return snapshot?.runtime.first { $0.fanIndex == fanIndex }?.modeLabel
                ?? L.t("자동", "Auto")
        }
        return profile.setting(for: fanIndex).mode.label
    }

    var activeFan: FanInfo? {
        fans.first { $0.index == selectedFanIndex } ?? fans.first
    }

    /// 그래프용 시계열.
    ///
    /// 점을 그대로 다 넘기면 15분 구간이 900점이 된다. 폭이 몇백 픽셀인 그래프에
    /// 그만큼 그리면 보이지도 않으면서 매 갱신마다 비용만 든다. 균등 간격으로 솎아낸다.
    private static let maxChartPoints = 120

    private func downsample(_ points: [(Date, Double)]) -> [(Date, Double)] {
        guard points.count > Self.maxChartPoints else { return points }
        let step = Double(points.count) / Double(Self.maxChartPoints)
        var result: [(Date, Double)] = []
        result.reserveCapacity(Self.maxChartPoints + 1)
        var pos = 0.0
        while Int(pos) < points.count {
            result.append(points[Int(pos)])
            pos += step
        }
        // 가장 최근 값은 반드시 남긴다. 지금 값이 안 보이면 그래프가 멈춘 것처럼 보인다.
        if let last = points.last, result.last?.0 != last.0 { result.append(last) }
        return result
    }

    /// 틱마다 미리 만들어 둔 시리즈를 돌려준다. 뷰에서 계산하지 않는다.
    func history(forKey key: String) -> [(Date, Double)] {
        series[key] ?? []
    }

    func fanHistory(index: Int) -> [(Date, Double)] {
        fanSeries[index] ?? []
    }

    func statistics(forKey key: String) -> SensorStatistics? {
        statistics[key]
    }

    // MARK: 데몬에 요청

    func refreshConfig() {
        Task.detached(priority: .utility) {
            let result = try? IPCClient.send(.getConfig, timeout: 2.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if case .config(let c)? = result {
                    self.setLanguage(c.language)
                    // 아직 보내지 않은 변경이 있으면 덮어쓰지 않는다.
                    // (슬라이더를 움직이는 중에 값이 되돌아가 보이는 걸 막는다)
                    guard !self.hasPendingConfigChange else { return }
                    self.config = c
                    self.daemonAvailable = true
                } else if self.config == nil {
                    self.setLanguage(.system)
                    // 데몬이 없을 때도 UI 가 비어 보이지 않도록 기본 설정을 만들어 보여준다.
                    self.config = FanDeckConfig.makeDefault(fans: FanController.shared.readAllFans())
                }
            }
        }
    }

    private func sendAndRefresh(_ request: IPCRequest, onFailure message: String) {
        Task.detached(priority: .userInitiated) {
            do {
                _ = try IPCClient.send(request)
                await MainActor.run { [weak self] in self?.lastError = nil }
            } catch {
                await MainActor.run { [weak self] in self?.lastError = "\(message): \(error)" }
            }
            await MainActor.run { [weak self] in self?.refreshConfig() }
        }
    }

    func activate(profile: Profile) {
        config?.activeProfileID = profile.id
        sendAndRefresh(.activateProfile(profile.id), onFailure: "프로파일을 바꾸지 못했습니다")
    }

    @ObservationIgnored private var configSendTask: Task<Void, Never>?
    /// 아직 서비스로 보내지 않은 변경이 있는지. 작업이 끝나면 반드시 내려간다.
    @ObservationIgnored private var hasPendingConfigChange = false

    /// 설정을 바꾼다. 화면은 즉시 반영하고, 서비스로 보내는 건 살짝 미룬다.
    ///
    /// 커브 점을 끌면 프레임마다 설정이 바뀌는데, 그때마다 소켓으로 보내면
    /// 서비스가 초당 수십 번 설정 파일을 다시 쓰게 된다. 마지막 상태만 보내면 충분하다.
    func apply(config newConfig: FanDeckConfig) {
        setLanguage(newConfig.language)
        let appearanceChanged = config?.menuBarIconStyle != newConfig.menuBarIconStyle
            || config?.menuBarTwoLines != newConfig.menuBarTwoLines
        config = newConfig
        if appearanceChanged { onMenuBarAppearanceChange?() }
        // 단위나 표시 설정이 바뀌면 메뉴 막대 글자도 즉시 다시 만든다.
        updateMenuBarTitle()
        recomputeDerived()

        configSendTask?.cancel()
        hasPendingConfigChange = true
        configSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hasPendingConfigChange = false
            self.sendAndRefresh(.setConfig(newConfig), onFailure: "설정을 저장하지 못했습니다")
        }
    }

    func setFanMode(_ mode: FanMode, fanIndex: Int) {
        sendAndRefresh(.setFanMode(fanIndex: fanIndex, mode: mode),
                       onFailure: "팬 속도를 바꾸지 못했습니다")
    }

    func releaseAll() {
        sendAndRefresh(.releaseAll, onFailure: "자동 제어로 되돌리지 못했습니다")
    }

    func toggleFavorite(_ key: String) {
        guard var config else { return }
        if let idx = config.favoriteSensorKeys.firstIndex(of: key) {
            config.favoriteSensorKeys.remove(at: idx)
        } else {
            config.favoriteSensorKeys.append(key)
        }
        apply(config: config)
    }

    func isFavorite(_ key: String) -> Bool {
        config?.favoriteSensorKeys.contains(key) ?? false
    }

    // MARK: 프로세스 종료

    /// 종료를 요청한다. 다른 사용자(root 등) 소유 프로세스는 앱 권한으로 끝낼 수 없다.
    func terminate(_ process: ProcessEntry, force: Bool = false) {
        guard process.isOwnedByCurrentUser else {
            lastError = "\(process.name) 은(는) \(process.user) 소유라 이 앱에서 종료할 수 없습니다."
            return
        }
        if SystemMonitor.shared.terminate(pid: process.pid, force: force) {
            lastError = nil
            processes.removeAll { $0.pid == process.pid }
        } else {
            lastError = "\(process.name) 을(를) 종료하지 못했습니다."
        }
    }

    // MARK: 메뉴바 표시용

    /// 메뉴 막대에 띄우는 글자.
    ///
    /// 계산 속성으로 두면 모델의 어떤 값이 바뀌든 메뉴 막대가 다시 그려지고,
    /// 그때마다 글자 폭이 달라질 수 있어 메뉴 막대 전체 레이아웃이 다시 계산된다.
    /// 창을 닫아 둬도 CPU 를 쓰던 원인이 이것이었다.
    /// 저장해 두고 **글자가 실제로 달라졌을 때만** 바꾼다.
    private(set) var menuBarTitle: String = "FanDeck"
    /// 메뉴 막대 아이템에 글자가 바뀌었음을 알린다(AppKit 쪽에서 받는다).
    @ObservationIgnored var onMenuBarTitleChange: ((String) -> Void)?
    /// 아이콘 표시 방식 등 메뉴 막대 설정이 바뀌었을 때 알린다.
    @ObservationIgnored var onMenuBarAppearanceChange: (() -> Void)?

    private func updateMenuBarTitle() {
        var parts: [String] = []
        if config?.menuBarShowsFan ?? true {
            // 어느 팬을 보여줄지 고를 수 있다. 지정이 없으면 첫 번째.
            let index = config?.menuBarFanIndex
            let fan = index.flatMap { idx in fans.first { $0.index == idx } } ?? fans.first
            if let fan { parts.append("\(Int(fan.currentRPM))rpm") }
        }
        if config?.menuBarShowsTemperature ?? true {
            let key = config?.menuBarSensorKey ?? SensorCatalog.cpuMaxKey
            if let v = readings[key], let d = descriptorsByKey[key] {
                parts.append(format.compactString(v, unit: d.unit))
            }
        }
        // 두 줄로 나누면 메뉴 막대 가로 폭을 아낄 수 있다.
        let separator = (config?.menuBarTwoLines ?? false) ? "\n" : " · "
        let newTitle = parts.isEmpty ? "FanDeck" : parts.joined(separator: separator)
        if newTitle != menuBarTitle {
            menuBarTitle = newTitle
            onMenuBarTitleChange?(newTitle)
        }
    }

    /// 창이 실제로 떠 있는지 직접 확인한다.
    /// SwiftUI Window 의 onDisappear 는 창을 닫아도 호출되지 않을 수 있어서 믿을 수 없다.
    /// 메뉴 막대 팝오버는 폭이 좁아서 크기로 구분된다.
    private func refreshWindowVisibility() {
        let visible = NSApp.windows.contains { window in
            window.isVisible && window.frame.width > 400 && window.frame.height > 300
        }
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible

        // 창을 닫으면 Dock 아이콘도 치운다. 메뉴 막대에 상주하는 앱이라
        // 창이 없는데 Dock 을 차지할 이유가 없다. 창을 다시 열면 되돌린다.
        // 설정에서 "독에 아이콘 표시" 를 켜면 창과 무관하게 항상 남는다.
        // (정책을 바꿀 때 깜빡임이 있어서 실제로 달라질 때만 호출한다.)
        let alwaysShowDock = config?.showDockIcon ?? false
        let policy: NSApplication.ActivationPolicy = (visible || alwaysShowDock) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func setLanguage(_ newValue: AppLanguage) {
        let changed = L.language != newValue
        L.language = newValue
        if language != newValue { language = newValue }
        // 센서 이름은 목록을 만들 때 정해지므로, 언어가 바뀌면 다시 만들어야 한다.
        if changed { loadDescriptors() }
    }

    /// 아직 보내지 않은 설정 변경을 지금 바로 보낸다.
    ///
    /// 설정 전송은 0.3초 미뤄 두는데, 그 사이에 앱이 꺼지면 변경이 사라진다.
    /// 종료 직전에 한 번 비워 준다.
    func flushPendingConfig() {
        guard hasPendingConfigChange, let config else { return }
        configSendTask?.cancel()
        hasPendingConfigChange = false
        // 종료 중이라 비동기로 보내면 늦는다. 동기로 보낸다.
        _ = try? IPCClient.send(.setConfig(config), timeout: 2)
    }

    /// 메뉴 막대에서 창을 열 때 쓴다. Dock 아이콘을 먼저 되살려야
    /// 창이 앞으로 나오고 메뉴 막대도 이 앱 것으로 바뀐다.
    func presentMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
