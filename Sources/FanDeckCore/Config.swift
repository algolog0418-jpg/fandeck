//  Config.swift — 프로파일과 설정 모델
//
//  설정 파일은 데몬이 소유한다(/Library/Application Support/FanDeck/config.json).
//  앱은 직접 쓰지 않고 소켓으로 데몬에 바꿔 달라고 요청한다. 그래야 앱을 꺼도,
//  로그인하기 전에도 같은 설정이 유지된다.

import Foundation

public enum FanDeckPaths {
    public static let supportDirectory = "/Library/Application Support/FanDeck"
    public static let configFile = supportDirectory + "/config.json"
    public static let socketPath = "/var/run/fandeck.sock"
    public static let daemonLabel = "com.fandeck.daemon"
    public static let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
    public static let daemonBinary = "/usr/local/libexec/fandeckd"
    public static let cliBinary = "/usr/local/bin/fandeck"
    public static let logFile = "/var/log/fandeck.log"
}

/// 프로파일을 자동으로 바꿀 조건.
public enum ProfileTrigger: Codable, Hashable, Sendable {
    /// 수동 전환만.
    case manual
    /// 지정한 프로세스 중 하나라도 실행 중이면 이 프로파일로 바꾼다.
    case appRunning(names: [String])
    /// 지정 센서가 임계값을 넘으면 전환.
    case sensorAbove(key: String, value: Double)

    public var label: String {
        switch self {
        case .manual: return L.t("수동", "Manual")
        case .appRunning(let names):
            return L.t("앱 실행 시 (\(names.joined(separator: ", ")))",
                       "When running (\(names.joined(separator: ", ")))")
        case .sensorAbove(_, let v):
            return L.t("온도 \(Int(v))°C 초과 시", "Above \(Int(v))°C")
        }
    }
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var fanSettings: [FanSetting]
    public var smoothing: SmoothingSettings
    public var trigger: ProfileTrigger
    /// 내장 프로파일은 이름 변경·삭제를 막는다.
    public var isBuiltIn: Bool
    /// 자동 전환 우선순위. 조건을 만족하는 프로파일이 여럿이면 높은 쪽이 이긴다.
    public var priority: Int

    public init(id: UUID = UUID(), name: String, symbol: String,
                fanSettings: [FanSetting],
                smoothing: SmoothingSettings = SmoothingSettings(),
                trigger: ProfileTrigger = .manual,
                isBuiltIn: Bool = false, priority: Int = 0) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.fanSettings = fanSettings
        self.smoothing = smoothing
        self.trigger = trigger
        self.isBuiltIn = isBuiltIn
        self.priority = priority
    }

    /// 화면에 띄울 이름. 내장 프로파일은 설정 파일에 한국어로 저장돼 있어서
    /// 영어로 쓸 때는 여기서 바꿔 준다. 사용자가 만든 프로파일 이름은 건드리지 않는다.
    public var displayName: String {
        guard isBuiltIn else { return name }
        switch name {
        case "시스템 자동": return L.t("시스템 자동", "System automatic")
        case "조용함":     return L.t("조용함", "Quiet")
        case "균형":       return L.t("균형", "Balanced")
        case "성능":       return L.t("성능", "Performance")
        case "최고 속도":   return L.t("최고 속도", "Maximum")
        default:           return name
        }
    }

    public func setting(for fanIndex: Int) -> FanSetting {
        fanSettings.first { $0.fanIndex == fanIndex }
            ?? FanSetting(fanIndex: fanIndex, mode: .automatic)
    }
}

/// 메뉴 막대에 아이콘을 어떻게 띄울지.
public enum MenuBarIconStyle: String, Codable, Sendable, CaseIterable {
    case monochrome, colored, hidden

    public var localizedName: String {
        switch self {
        case .monochrome: return L.t("보이기 (검은색 & 흰색)", "Show (black & white)")
        case .colored:    return L.t("보이기 (색상)", "Show (colored)")
        case .hidden:     return L.t("숨기기", "Hide")
        }
    }
}

public struct FanDeckConfig: Codable, Hashable, Sendable {
    /// 설정 구조의 판 번호.
    ///
    /// 항목을 새로 추가할 때마다 올린다. 서비스는 자기가 아는 구조로만 설정을
    /// 읽고 쓰기 때문에, 앱만 새로 깔면 새 항목이 조용히 사라진다.
    /// 앱은 이 번호를 서비스가 보내 준 값과 비교해서 그 상황을 알아챈다.
    /// (바이너리 크기 비교는 관계없는 변경에도 반응해서 쓸 수 없었다.)
    public static let schemaVersion = 4

    public var version: Int
    public var activeProfileID: UUID
    public var profiles: [Profile]
    public var safety: SafetySettings
    /// 데몬 제어 주기(초).
    public var tickInterval: Double
    /// 자동 전환 규칙 사용 여부.
    public var autoSwitchEnabled: Bool
    /// 메뉴바에 표시할 센서.
    public var menuBarSensorKey: String
    public var menuBarShowsFan: Bool
    public var menuBarShowsTemperature: Bool
    /// 온도 경고 알림 임계값. nil 이면 끔.
    public var notifyAboveTemperature: Double?
    /// 데몬이 시계열로 기록할 센서 키. 기본값에 즐겨찾기가 더해진다.
    public var historySensorKeys: [String]
    /// 대시보드 상단에 고정해 둘 센서.
    public var favoriteSensorKeys: [String]
    /// 기록 보관 시간(초). 기본 6시간.
    public var historyRetentionSeconds: Double

    // MARK: 표시 설정
    /// 온도 단위. SMC 는 섭씨를 주고, 표시 직전에만 바꾼다.
    public var temperatureUnit: TemperatureUnit
    /// 소수점 한 자리까지 보여줄지 (45.4 vs 45).
    public var showDecimals: Bool

    // MARK: 일반
    /// 창을 닫으면 Dock 아이콘을 감출지. 끄면 창이 없어도 Dock 에 남는다.
    public var showDockIcon: Bool
    /// 로그인 후 자동 실행될 때 창을 띄우지 않고 메뉴 막대로만 시작할지.
    public var startMinimized: Bool
    /// 앱을 켤 때 새 버전이 있는지 GitHub 에서 확인할지.
    public var checkUpdatesOnLaunch: Bool

    // MARK: 메뉴 막대
    public var menuBarIconStyle: MenuBarIconStyle
    /// 메뉴 막대에 표시할 팬. nil 이면 첫 번째 팬.
    public var menuBarFanIndex: Int?
    /// 팬과 센서를 두 줄로 나눠 표시해 가로 공간을 아낀다.
    public var menuBarTwoLines: Bool

    // MARK: 센서
    /// 외장(USB·Thunderbolt) 드라이브 온도까지 읽을지. 읽는 데 시간이 조금 걸린다.
    public var includeExternalDrives: Bool

    /// 화면에 쓸 언어.
    public var language: AppLanguage

    /// 표시 규칙을 한 덩어리로 넘길 때 쓴다.
    public var valueFormat: ValueFormat {
        ValueFormat(temperatureUnit: temperatureUnit, showDecimals: showDecimals)
    }

    public init(version: Int = 1,
                activeProfileID: UUID,
                profiles: [Profile],
                safety: SafetySettings = SafetySettings(),
                tickInterval: Double = 1.0,
                autoSwitchEnabled: Bool = false,
                menuBarSensorKey: String = SensorCatalog.cpuMaxKey,
                menuBarShowsFan: Bool = true,
                menuBarShowsTemperature: Bool = true,
                notifyAboveTemperature: Double? = nil,
                historySensorKeys: [String] = [SensorCatalog.cpuMaxKey,
                                               SensorCatalog.cpuAverageKey,
                                               SensorCatalog.gpuMaxKey,
                                               SensorCatalog.systemMaxKey,
                                               "PSTR"],
                favoriteSensorKeys: [String] = [SensorCatalog.cpuMaxKey,
                                                SensorCatalog.gpuMaxKey,
                                                "PSTR"],
                historyRetentionSeconds: Double = 6 * 3600,
                temperatureUnit: TemperatureUnit = .celsius,
                showDecimals: Bool = true,
                showDockIcon: Bool = false,
                startMinimized: Bool = false,
                checkUpdatesOnLaunch: Bool = true,
                menuBarIconStyle: MenuBarIconStyle = .monochrome,
                menuBarFanIndex: Int? = nil,
                menuBarTwoLines: Bool = false,
                includeExternalDrives: Bool = false,
                language: AppLanguage = .system) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.safety = safety
        self.tickInterval = tickInterval
        self.autoSwitchEnabled = autoSwitchEnabled
        self.menuBarSensorKey = menuBarSensorKey
        self.menuBarShowsFan = menuBarShowsFan
        self.menuBarShowsTemperature = menuBarShowsTemperature
        self.notifyAboveTemperature = notifyAboveTemperature
        self.historySensorKeys = historySensorKeys
        self.favoriteSensorKeys = favoriteSensorKeys
        self.historyRetentionSeconds = historyRetentionSeconds
        self.temperatureUnit = temperatureUnit
        self.showDecimals = showDecimals
        self.showDockIcon = showDockIcon
        self.startMinimized = startMinimized
        self.checkUpdatesOnLaunch = checkUpdatesOnLaunch
        self.menuBarIconStyle = menuBarIconStyle
        self.menuBarFanIndex = menuBarFanIndex
        self.menuBarTwoLines = menuBarTwoLines
        self.includeExternalDrives = includeExternalDrives
        self.language = language
    }

    /// 구버전 설정 파일에 없던 항목은 기본값으로 채운다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeProfileID = try c.decode(UUID.self, forKey: .activeProfileID)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        safety = try c.decodeIfPresent(SafetySettings.self, forKey: .safety) ?? SafetySettings()
        tickInterval = try c.decodeIfPresent(Double.self, forKey: .tickInterval) ?? 1.0
        autoSwitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchEnabled) ?? false
        menuBarSensorKey = try c.decodeIfPresent(String.self, forKey: .menuBarSensorKey) ?? SensorCatalog.cpuMaxKey
        menuBarShowsFan = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsFan) ?? true
        menuBarShowsTemperature = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsTemperature) ?? true
        notifyAboveTemperature = try c.decodeIfPresent(Double.self, forKey: .notifyAboveTemperature)
        historySensorKeys = try c.decodeIfPresent([String].self, forKey: .historySensorKeys)
            ?? [SensorCatalog.cpuMaxKey, SensorCatalog.cpuAverageKey,
                SensorCatalog.gpuMaxKey, SensorCatalog.systemMaxKey, "PSTR"]
        favoriteSensorKeys = try c.decodeIfPresent([String].self, forKey: .favoriteSensorKeys)
            ?? [SensorCatalog.cpuMaxKey, SensorCatalog.gpuMaxKey, "PSTR"]
        historyRetentionSeconds = try c.decodeIfPresent(Double.self, forKey: .historyRetentionSeconds) ?? 6 * 3600
        temperatureUnit = (try? c.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit)) ?? .celsius
        showDecimals = try c.decodeIfPresent(Bool.self, forKey: .showDecimals) ?? true
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        startMinimized = try c.decodeIfPresent(Bool.self, forKey: .startMinimized) ?? false
        checkUpdatesOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .checkUpdatesOnLaunch) ?? true
        menuBarIconStyle = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle)) ?? .monochrome
        menuBarFanIndex = try c.decodeIfPresent(Int.self, forKey: .menuBarFanIndex)
        menuBarTwoLines = try c.decodeIfPresent(Bool.self, forKey: .menuBarTwoLines) ?? false
        includeExternalDrives = try c.decodeIfPresent(Bool.self, forKey: .includeExternalDrives) ?? false
        // 나중에 언어가 늘어나면 예전 버전은 그 값을 모른다. 그대로 두면 디코딩이
        // 통째로 실패해서 설정 파일 전체가 날아간다. 모르는 값은 기본값으로 넘긴다.
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? .system
    }

    public var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// 팬의 실제 최소/최대 RPM 을 알아야 쓸 만한 기본 커브가 나오므로 인자로 받는다.
    ///
    /// 팬마다 회전 범위가 다를 수 있어서(맥북의 좌우 팬이 다른 경우가 있다)
    /// 하나로 뭉뚱그리지 않고 각 팬의 범위로 따로 만든다.
    public static func makeDefault(fans: [FanInfo]) -> FanDeckConfig {
        // 팬을 못 찾은 경우에만 쓰는 값. 실제 팬이 있으면 언제나 그 팬의 값을 쓴다.
        let fallbackMin = 1200.0, fallbackMax = 4000.0
        let targets: [(index: Int, minRPM: Double, maxRPM: Double)] = fans.isEmpty
            ? [(0, fallbackMin, fallbackMax)]
            : fans.map { ($0.index, $0.minRPM, $0.maxRPM) }
        let maxRPM = targets.map(\.maxRPM).max() ?? fallbackMax

        func curveSettings(_ scale: (Double) -> Double, temps: [Double]) -> [FanSetting] {
            targets.map { target in
                let points = zip(temps, temps.indices).map { (t, i) -> CurvePoint in
                    let frac = Double(i) / Double(max(temps.count - 1, 1))
                    return CurvePoint(temperature: t,
                                      rpm: target.minRPM
                                           + (target.maxRPM - target.minRPM) * scale(frac))
                }
                return FanSetting(fanIndex: target.index,
                                  mode: .curve(FanCurve(sensorKey: SensorCatalog.cpuMaxKey,
                                                        points: points)))
            }
        }

        let indices = targets.map(\.index)

        let silent = Profile(
            name: "조용함", symbol: "moon.zzz.fill",
            fanSettings: curveSettings({ pow($0, 2.2) }, temps: [50, 65, 78, 88, 96]),
            smoothing: SmoothingSettings(temperatureSmoothing: 0.25, hysteresis: 5,
                                         rampUpPerSecond: 250, rampDownPerSecond: 80),
            isBuiltIn: true)

        let balanced = Profile(
            name: "균형", symbol: "dial.medium.fill",
            fanSettings: curveSettings({ pow($0, 1.5) }, temps: [45, 58, 70, 82, 93]),
            smoothing: SmoothingSettings(),
            isBuiltIn: true)

        let performance = Profile(
            name: "성능", symbol: "bolt.fill",
            fanSettings: curveSettings({ pow($0, 1.0) }, temps: [40, 52, 64, 75, 85]),
            smoothing: SmoothingSettings(temperatureSmoothing: 0.5, hysteresis: 2,
                                         rampUpPerSecond: 800, rampDownPerSecond: 200),
            isBuiltIn: true)

        let maxProfile = Profile(
            name: "최고 속도", symbol: "gauge.high",
            fanSettings: targets.map { FanSetting(fanIndex: $0.index, mode: .fixed(rpm: $0.maxRPM)) },
            smoothing: SmoothingSettings(rampUpPerSecond: 2000, rampDownPerSecond: 2000),
            isBuiltIn: true)

        let system = Profile(
            name: "시스템 자동", symbol: "apple.logo",
            fanSettings: indices.map { FanSetting(fanIndex: $0, mode: .automatic) },
            isBuiltIn: true)

        return FanDeckConfig(activeProfileID: system.id,
                             profiles: [system, silent, balanced, performance, maxProfile])
    }

    /// 저장된 설정을 지금 이 맥의 팬에 맞춘다.
    ///
    /// 설정 파일은 팬 회전수를 그대로 담고 있어서, 다른 맥(또는 팬이 교체된 맥)에서
    /// 열면 커브가 그 팬의 범위를 벗어날 수 있다. 예를 들어 최대 4900rpm 으로 그린 커브를
    /// 최대 2000rpm 인 맥에서 쓰면 곡선의 윗부분이 통째로 잘린다.
    ///
    /// 넘치는 경우에는 곡선 모양을 지키려고 비율로 줄이고, 모자라는 쪽은 최소값으로만 올린다.
    /// (사용자가 일부러 좁은 범위로 그렸을 수 있어서 억지로 늘리지는 않는다.)
    /// 바뀐 내용이 있으면 true 를 돌려준다.
    @discardableResult
    public mutating func adapt(to fans: [FanInfo]) -> Bool {
        guard !fans.isEmpty else { return false }
        var changed = false

        for profileIndex in profiles.indices {
            for settingIndex in profiles[profileIndex].fanSettings.indices {
                let setting = profiles[profileIndex].fanSettings[settingIndex]
                guard let fan = fans.first(where: { $0.index == setting.fanIndex }),
                      fan.maxRPM > fan.minRPM else { continue }

                switch setting.mode {
                case .automatic:
                    continue

                case .fixed(let rpm):
                    let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
                    if abs(clamped - rpm) > 1 {
                        profiles[profileIndex].fanSettings[settingIndex].mode = .fixed(rpm: clamped)
                        changed = true
                    }

                case .curve(var curve):
                    let highest = curve.points.map(\.rpm).max() ?? 0
                    var points = curve.points

                    if highest > fan.maxRPM {
                        // 곡선 전체를 비율로 줄여 모양을 지킨다.
                        let scale = (fan.maxRPM - fan.minRPM) / max(highest - fan.minRPM, 1)
                        points = points.map {
                            CurvePoint(temperature: $0.temperature,
                                       rpm: fan.minRPM + ($0.rpm - fan.minRPM) * scale)
                        }
                    }
                    // 최소 회전수보다 낮은 점만 끌어올린다.
                    points = points.map {
                        CurvePoint(temperature: $0.temperature,
                                   rpm: min(max($0.rpm, fan.minRPM), fan.maxRPM))
                    }

                    if points != curve.points {
                        curve.points = points
                        profiles[profileIndex].fanSettings[settingIndex].mode = .curve(curve)
                        changed = true
                    }
                }
            }

            // 이 맥에 없는 팬에 대한 설정은 치운다. 팬이 새로 생겼다면 자동으로 채운다.
            let known = Set(fans.map(\.index))
            let before = profiles[profileIndex].fanSettings.count
            profiles[profileIndex].fanSettings.removeAll { !known.contains($0.fanIndex) }
            for fan in fans where !profiles[profileIndex].fanSettings.contains(where: { $0.fanIndex == fan.index }) {
                profiles[profileIndex].fanSettings.append(
                    FanSetting(fanIndex: fan.index, mode: .automatic))
            }
            if profiles[profileIndex].fanSettings.count != before { changed = true }
        }
        return changed
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> FanDeckConfig {
        try JSONDecoder().decode(FanDeckConfig.self, from: data)
    }
}
