//  Sensors.swift — SMC 키를 사람이 읽을 수 있는 센서로 바꾸는 카탈로그
//
//  Apple Silicon 의 SMC 키 이름은 문서화돼 있지 않다. 이 맥(M4 / Mac16,10)의
//  실제 키 덤프를 기준으로 접두사 규칙을 정리했고, 모르는 키는 버리지 않고
//  "기타" 그룹에 원래 키 이름 그대로 남긴다.
//
//  코어 센서는 다이 하나당 2~3개가 연속된 키로 묶여 나온다.
//  예: 성능 코어 1 = Tp00(주변부) / Tp01(코어 다이) / Tp02(핫스팟)
//
//  이 중 "코어 온도"로 통용되는 값은 가운데 키(Tp01)다. 다른 팬 제어 앱들도
//  이 값을 "CPU Performance Core 1"로 표시한다. 핫스팟(Tp02)은 같은 코어 영역에서
//  가장 뜨거운 지점이라 10도 이상 높게 나오는데, 이걸 코어 온도로 쓰면
//  다른 앱과 숫자가 어긋나 보인다. 그래서 대표값은 코어 다이로 두고,
//  핫스팟은 별도 센서로 따로 노출한다(과열 보호에는 핫스팟이 더 안전하다).

import Foundation

/// 온도를 어떤 단위로 보여줄지.
public enum TemperatureUnit: String, Codable, Sendable, CaseIterable {
    case celsius, fahrenheit

    public var suffix: String { self == .celsius ? "°C" : "°F" }
    public var shortSuffix: String { self == .celsius ? "°" : "°F" }

    /// SMC 는 항상 섭씨를 주므로, 표시 직전에만 변환한다.
    public func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// 사용자가 입력한 값(커브 온도 등)을 섭씨로 되돌린다.
    public func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32) * 5 / 9
    }

    public var localizedName: String {
        self == .celsius ? "섭씨 (°C)" : "화씨 (°F)"
    }
}

/// 값 표시 규칙을 한곳에 모은다. 단위·소수점 설정이 모든 화면에 똑같이 적용돼야 한다.
public struct ValueFormat: Sendable, Hashable {
    public var temperatureUnit: TemperatureUnit
    /// 끄면 정수로만 보여준다(45.4 → 45).
    public var showDecimals: Bool

    public init(temperatureUnit: TemperatureUnit = .celsius, showDecimals: Bool = true) {
        self.temperatureUnit = temperatureUnit
        self.showDecimals = showDecimals
    }

    public static let `default` = ValueFormat()

    /// 센서 값 하나를 문자열로. 온도는 설정된 단위로 변환해서 보여준다.
    public func string(_ value: Double, unit: SensorUnit, includeSuffix: Bool = true) -> String {
        if unit == .celsius {
            let converted = temperatureUnit.convert(value)
            let digits = showDecimals ? 1 : 0
            let number = String(format: "%.\(digits)f", converted)
            return includeSuffix ? number + temperatureUnit.suffix : number
        }
        let digits = showDecimals ? unit.fractionDigits : 0
        let number = String(format: "%.\(digits)f", value)
        return includeSuffix ? number + unit.suffix : number
    }

    /// 메뉴 막대처럼 자리가 좁은 곳용 — 항상 정수.
    public func compactString(_ value: Double, unit: SensorUnit) -> String {
        if unit == .celsius {
            return "\(Int(temperatureUnit.convert(value).rounded()))" + temperatureUnit.shortSuffix
        }
        return String(format: "%.0f%@", value, unit.suffix)
    }
}

public enum SensorUnit: String, Codable, Sendable {
    case celsius, watt, volt, ampere, rpm, percent

    public var suffix: String {
        switch self {
        case .celsius: return "°C"
        case .watt:    return "W"
        case .volt:    return "V"
        case .ampere:  return "A"
        case .rpm:     return "rpm"
        case .percent: return "%"
        }
    }

    /// 표시 소수점 자리수. 온도는 1자리면 충분하고 전압은 더 필요하다.
    public var fractionDigits: Int {
        switch self {
        case .celsius: return 1
        case .watt:    return 2
        case .volt:    return 3
        case .ampere:  return 3
        case .rpm:     return 0
        case .percent: return 0
        }
    }
}

public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpuPerformance, cpuEfficiency, cpu, gpu, memory, storage
    case power, voltage, current, powerStage, ambient, wireless, thermalZone, other

    public var localizedName: String {
        switch self {
        case .cpuPerformance: return "CPU 성능 코어"
        case .cpuEfficiency:  return "CPU 효율 코어"
        case .cpu:            return "CPU 기타"
        case .gpu:            return "GPU"
        case .memory:         return "메모리"
        case .storage:        return "저장장치"
        case .power:          return "전력"
        case .voltage:        return "전압"
        case .current:        return "전류"
        case .powerStage:     return "전원부"
        case .ambient:        return "주변 온도"
        case .wireless:       return "무선"
        case .thermalZone:    return "열 구역"
        case .other:          return "기타"
        }
    }

    public var englishName: String {
        switch self {
        case .cpuPerformance: return "CPU Performance Cores"
        case .cpuEfficiency:  return "CPU Efficiency Cores"
        case .cpu:            return "CPU Other"
        case .gpu:            return "GPU"
        case .memory:         return "Memory"
        case .storage:        return "Storage"
        case .power:          return "Power"
        case .voltage:        return "Voltage"
        case .current:        return "Current"
        case .powerStage:     return "Power Stage"
        case .ambient:        return "Ambient"
        case .wireless:       return "Wireless"
        case .thermalZone:    return "Thermal Zone"
        case .other:          return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpu: return "cpu"
        case .gpu:         return "cpu.fill"
        case .memory:      return "memorychip"
        case .storage:     return "internaldrive"
        case .power:       return "bolt.fill"
        case .voltage:     return "bolt"
        case .current:     return "bolt.horizontal"
        case .powerStage:  return "powerplug"
        case .ambient:     return "wind"
        case .wireless:    return "wifi"
        case .thermalZone: return "thermometer.medium"
        case .other:       return "sensor"
        }
    }

    /// 온도 단위 그룹인지. 팬 커브의 소스 후보를 추릴 때 쓴다.
    public var isTemperature: Bool {
        switch self {
        case .power, .voltage, .current: return false
        default: return true
        }
    }
}

public struct SensorDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let key: String
    public let name: String
    public let englishName: String
    public let group: SensorGroup
    public let unit: SensorUnit
    /// 합성 센서(여러 키의 평균·최대)는 SMC 키가 아니라 계산으로 만든다.
    public let isSynthetic: Bool
    /// 합성 센서가 참조하는 실제 키 목록.
    public let sourceKeys: [String]
    public let aggregation: Aggregation

    public enum Aggregation: String, Codable, Sendable { case raw, average, maximum }

    public var id: String { key }

    public init(key: String, name: String, englishName: String, group: SensorGroup,
                unit: SensorUnit = .celsius, isSynthetic: Bool = false,
                sourceKeys: [String] = [], aggregation: Aggregation = .raw) {
        self.key = key
        self.name = name
        self.englishName = englishName
        self.group = group
        self.unit = unit
        self.isSynthetic = isSynthetic
        self.sourceKeys = sourceKeys
        self.aggregation = aggregation
    }
}

/// 실제 읽은 값 하나.
public struct SensorReading: Identifiable, Hashable, Sendable {
    public let descriptor: SensorDescriptor
    public let value: Double
    public var id: String { descriptor.key }

    public init(descriptor: SensorDescriptor, value: Double) {
        self.descriptor = descriptor
        self.value = value
    }

    public var formatted: String {
        let d = descriptor.unit.fractionDigits
        return String(format: "%.\(d)f%@", value, descriptor.unit.suffix)
    }
}

public enum SensorCatalog {

    /// 다이 하나를 이루는 연속 키 묶음. 대표값은 묶음 내 최대값.
    private struct CoreCluster {
        let keys: [String]
        let index: Int
    }

    /// M4 계열에서 관찰된 코어 센서 묶음. 키 접미사는 16진 증가 패턴을 따른다.
    private static let performanceClusters: [[String]] = [
        ["Tp00", "Tp01", "Tp02"],
        ["Tp04", "Tp05", "Tp06"],
        ["Tp08", "Tp09", "Tp0A"],
        ["Tp0C", "Tp0D", "Tp0E"],
    ]

    private static let efficiencyClusters: [[String]] = [
        ["Te04", "Te05", "Te06"],
        ["Te08", "Te09", "Te0A"],
        ["Te0G", "Te0H", "Te0I"],
        ["Te0R", "Te0S", "Te0T"],
        ["Te0U", "Te0V"],
        ["Te0W", "Te0X"],
    ]

    private static let gpuClusters: [[String]] = [
        ["Tg0C", "Tg0D"], ["Tg0G", "Tg0H"], ["Tg0K", "Tg0L"],
        ["Tg0O", "Tg0P"], ["Tg0U", "Tg0V"], ["Tg0X", "Tg0Y"],
        ["Tg0d", "Tg0e"], ["Tg0j", "Tg0k"], ["Tg0m", "Tg0n"],
    ]

    /// 접두사만으로 판별되는 키들. 구체적인 이름을 붙일 수 있는 것만 적는다.
    private static let namedKeys: [String: (String, String, SensorGroup, SensorUnit)] = [
        "TW0P": ("무선(Wi-Fi) 근접", "Airport Proximity", .wireless, .celsius),
        "TT0P": ("Thunderbolt 근접", "Thunderbolt Proximity", .other, .celsius),
        "Tm0p": ("메모리 근접 1", "Memory Proximity 1", .memory, .celsius),
        "Tm1p": ("메모리 근접 2", "Memory Proximity 2", .memory, .celsius),
        "Tm2p": ("메모리 근접 3", "Memory Proximity 3", .memory, .celsius),
        "TH0a": ("SSD A", "SSD A", .storage, .celsius),
        "TH0b": ("SSD B", "SSD B", .storage, .celsius),
        "TH0p": ("SSD 근접", "SSD Proximity", .storage, .celsius),
        "TH0x": ("SSD 컨트롤러", "SSD Controller", .storage, .celsius),
        "TCMb": ("SoC 다이 평균", "SoC Die Average", .cpu, .celsius),
        "TCMz": ("SoC 다이 최고", "SoC Die Peak", .cpu, .celsius),
        "Ta0p": ("흡기 공기", "Airflow Intake", .ambient, .celsius),
        "TSCD": ("시스템 컨트롤러", "System Controller", .other, .celsius),
        "TIED": ("입력 전원부", "Input Power Stage", .powerStage, .celsius),
        "TMVR": ("메모리 레귤레이터", "Memory VR", .powerStage, .celsius),
        "TUVR": ("보조 레귤레이터", "Auxiliary VR", .powerStage, .celsius),
        "TPSD": ("전원 공급부", "Power Supply", .powerStage, .celsius),
        "TPSP": ("전원 공급부 근접", "Power Supply Proximity", .powerStage, .celsius),
        "TfC0": ("팬 컨트롤러 1", "Fan Controller 1", .other, .celsius),
        "TfC1": ("팬 컨트롤러 2", "Fan Controller 2", .other, .celsius),
        // Intel 맥에서 쓰이는 키들. Apple Silicon 에는 없으므로 있을 때만 잡힌다.
        "TC0D": ("CPU 다이", "CPU Die", .cpu, .celsius),
        "TC0P": ("CPU 근접", "CPU Proximity", .cpu, .celsius),
        "TC0H": ("CPU 히트싱크", "CPU Heatsink", .cpu, .celsius),
        "TG0D": ("GPU 다이", "GPU Die", .gpu, .celsius),
        "TG0P": ("GPU 근접", "GPU Proximity", .gpu, .celsius),
        "TA0P": ("주변 공기", "Ambient Air", .ambient, .celsius),
        "TM0P": ("메모리 근접", "Memory Proximity", .memory, .celsius),
        "Th0H": ("히트파이프", "Heatpipe", .other, .celsius),
        "TB0T": ("배터리", "Battery", .other, .celsius),
        "Ts0P": ("팜레스트", "Palm Rest", .ambient, .celsius),

        "PSTR": ("시스템 총 전력", "System Total Power", .power, .watt),
        "PDTR": ("DC 입력 전력", "DC Input Power", .power, .watt),
        "PHPC": ("CPU 패키지 전력", "CPU Package Power", .power, .watt),
        "PHPM": ("메모리 전력", "Memory Power", .power, .watt),
        "PHPS": ("SoC 전력", "SoC Power", .power, .watt),
        "PHPB": ("GPU 전력", "GPU Power", .power, .watt),
        "PPMR": ("메인 레일 전력", "Main Rail Power", .power, .watt),
        "PMVC": ("메모리 VRM 전력", "Memory VRM Power", .power, .watt),
    ]

    /// 접두사 → (그룹, 단위, 한국어 라벨, 영어 라벨)
    private static let prefixRules: [(String, SensorGroup, SensorUnit, String, String)] = [
        ("Tp", .cpu,        .celsius, "CPU 영역",   "CPU Zone"),
        ("Te", .cpu,        .celsius, "CPU 영역",   "CPU Zone"),
        ("Tg", .gpu,        .celsius, "GPU 영역",   "GPU Zone"),
        ("Ts", .ambient,    .celsius, "표면",       "Surface"),
        ("Ta", .ambient,    .celsius, "공기",       "Airflow"),
        ("Tz", .thermalZone,.celsius, "열 구역",    "Thermal Zone"),
        ("TP", .powerStage, .celsius, "전원부",     "Power Stage"),
        ("TR", .powerStage, .celsius, "레귤레이터", "Regulator"),
        ("TV", .powerStage, .celsius, "전압 레귤레이터", "Voltage Regulator"),
        ("TH", .storage,    .celsius, "저장장치",   "Storage"),
        ("Tm", .memory,     .celsius, "메모리",     "Memory"),
        ("T",  .other,      .celsius, "온도",       "Temperature"),
        ("P",  .power,      .watt,    "전력",       "Power"),
        ("V",  .voltage,    .volt,    "전압",       "Voltage"),
        ("I",  .current,    .ampere,  "전류",       "Current"),
    ]

    /// 합성 센서 키는 SMC 키와 겹치지 않도록 '@' 로 시작한다.
    public static let cpuAverageKey = "@CPUAVG"
    public static let cpuMaxKey     = "@CPUMAX"
    public static let cpuHotspotKey = "@CPUHOT"
    public static let gpuAverageKey = "@GPUAVG"
    public static let gpuMaxKey     = "@GPUMAX"
    public static let systemMaxKey  = "@SYSMAX"

    /// 이 맥의 키 구성이 위에 적어 둔 배치와 맞는지 확인한다.
    ///
    /// 코어 묶음은 M4 Mac mini 에서 실측해 적은 것이다. 다른 기종은 키 배열이 다를 수 있는데,
    /// 그때도 같은 규칙으로 이름을 붙이면 **엉뚱한 센서에 "성능 코어 1" 이라는 이름이 붙는다**.
    /// 틀린 이름을 보여주느니, 아는 배치일 때만 이름을 붙이고 나머지는 키를 그대로 보여준다.
    private static func layoutMatches(_ clusters: [[String]], _ keys: Set<String>) -> Bool {
        let present = clusters.filter { cluster in cluster.allSatisfy { keys.contains($0) } }
        // 절반 이상이 통째로 들어맞아야 같은 배치로 본다.
        return !clusters.isEmpty && present.count * 2 >= clusters.count
    }

    /// SMC 에서 읽은 키 목록을 받아 설명자 전체를 만든다.
    public static func build(availableKeys: Set<String>) -> [SensorDescriptor] {
        var result: [SensorDescriptor] = []
        var consumed = Set<String>()

        // 코어 다이 센서와 핫스팟 센서를 따로 모아둔다. 집계 센서를 만들 때 쓴다.
        var coreKeys: [SensorGroup: [String]] = [:]
        var hotspotKeys: [String] = []

        func addClusters(_ clusters: [[String]], group: SensorGroup,
                         koPrefix: String, enPrefix: String) {
            var index = 1
            for cluster in clusters {
                let present = cluster.filter { availableKeys.contains($0) }
                guard !present.isEmpty else { continue }

                // 코어 다이는 묶음의 두 번째 키. 묶음이 하나뿐이면 그걸 쓴다.
                let coreKey = present.count >= 2 ? present[1] : present[0]
                result.append(SensorDescriptor(
                    key: coreKey,
                    name: "\(koPrefix) \(index)",
                    englishName: "\(enPrefix) \(index)",
                    group: group,
                    unit: .celsius))
                coreKeys[group, default: []].append(coreKey)

                // 핫스팟 — 같은 코어에서 가장 뜨거운 지점.
                if present.count >= 3 {
                    result.append(SensorDescriptor(
                        key: present[2],
                        name: "\(koPrefix) \(index) 핫스팟",
                        englishName: "\(enPrefix) \(index) Hotspot",
                        group: .cpu,
                        unit: .celsius))
                    hotspotKeys.append(present[2])
                }

                // 주변부 — 코어를 둘러싼 더 낮은 온도의 측정점.
                if present.count >= 2 {
                    result.append(SensorDescriptor(
                        key: present[0],
                        name: "\(koPrefix) \(index) 주변부",
                        englishName: "\(enPrefix) \(index) Vicinity",
                        group: .cpu,
                        unit: .celsius))
                }

                consumed.formUnion(present)
                index += 1
            }
        }

        if layoutMatches(performanceClusters, availableKeys) {
            addClusters(performanceClusters, group: .cpuPerformance,
                        koPrefix: "성능 코어", enPrefix: "Performance Core")
        }
        if layoutMatches(efficiencyClusters, availableKeys) {
            addClusters(efficiencyClusters, group: .cpuEfficiency,
                        koPrefix: "효율 코어", enPrefix: "Efficiency Core")
        }
        if layoutMatches(gpuClusters, availableKeys) {
            addClusters(gpuClusters, group: .gpu,
                        koPrefix: "GPU 클러스터", enPrefix: "GPU Cluster")
        }

        // 합성 센서 — 팬 커브 소스로 쓰기 좋은 집계값들.
        // 코어 다이 센서만 모은다. 핫스팟을 섞으면 다른 앱이 보여주는 값과 어긋난다.
        var allCPU = (coreKeys[.cpuPerformance] ?? []) + (coreKeys[.cpuEfficiency] ?? [])
        var gCoreKeys = coreKeys[.gpu] ?? []

        // 배치를 모르는 기종에서는 접두사만 보고 모은다. 개별 이름은 못 붙여도
        // "CPU 최고 온도" 같은 집계값은 있어야 팬 커브를 걸 수 있다.
        if allCPU.isEmpty {
            allCPU = availableKeys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.sorted()
            // Intel 맥의 CPU 다이/근접 센서.
            allCPU += availableKeys.filter { ["TC0D", "TC0E", "TC0F", "TC0P", "TC1C", "TC2C", "TC3C", "TC4C"].contains($0) }
        }
        if gCoreKeys.isEmpty {
            gCoreKeys = availableKeys.filter { $0.hasPrefix("Tg") || $0 == "TG0D" || $0 == "TG0P" }.sorted()
        }

        if !allCPU.isEmpty {
            result.append(SensorDescriptor(key: cpuAverageKey, name: "CPU 코어 평균",
                englishName: "CPU Core Average", group: .cpu, unit: .celsius,
                isSynthetic: true, sourceKeys: allCPU, aggregation: .average))
            result.append(SensorDescriptor(key: cpuMaxKey, name: "CPU 최고 온도",
                englishName: "CPU Maximum", group: .cpu, unit: .celsius,
                isSynthetic: true, sourceKeys: allCPU, aggregation: .maximum))
        }
        if !hotspotKeys.isEmpty {
            // 과열 보호에는 이 값이 가장 안전하다 — 실제로 가장 먼저 뜨거워지는 지점이다.
            result.append(SensorDescriptor(key: cpuHotspotKey, name: "CPU 핫스팟",
                englishName: "CPU Hotspot", group: .cpu, unit: .celsius,
                isSynthetic: true, sourceKeys: hotspotKeys, aggregation: .maximum))
        }
        if !gCoreKeys.isEmpty {
            result.append(SensorDescriptor(key: gpuAverageKey, name: "GPU 평균",
                englishName: "GPU Average", group: .gpu, unit: .celsius,
                isSynthetic: true, sourceKeys: gCoreKeys, aggregation: .average))
            result.append(SensorDescriptor(key: gpuMaxKey, name: "GPU 최고 온도",
                englishName: "GPU Maximum", group: .gpu, unit: .celsius,
                isSynthetic: true, sourceKeys: gCoreKeys, aggregation: .maximum))
        }

        // 이름이 명시된 키들.
        for (key, meta) in namedKeys where availableKeys.contains(key) && !consumed.contains(key) {
            result.append(SensorDescriptor(key: key, name: meta.0, englishName: meta.1,
                                           group: meta.2, unit: meta.3))
            consumed.insert(key)
        }

        // 나머지는 접두사 규칙으로 분류하고 키 이름을 그대로 보여준다.
        var perGroupCount: [SensorGroup: Int] = [:]
        for key in availableKeys.sorted() where !consumed.contains(key) {
            guard let rule = prefixRules.first(where: { key.hasPrefix($0.0) }) else { continue }
            let n = (perGroupCount[rule.1] ?? 0) + 1
            perGroupCount[rule.1] = n
            result.append(SensorDescriptor(key: key,
                                           name: "\(rule.3) \(key)",
                                           englishName: "\(rule.4) \(key)",
                                           group: rule.1, unit: rule.2))
        }

        // 시스템 전체 최고 온도 — 안전장치의 기본 소스.
        let allTempKeys = result.filter { $0.group.isTemperature && !$0.isSynthetic }.map(\.key)
        if !allTempKeys.isEmpty {
            result.append(SensorDescriptor(key: systemMaxKey, name: "시스템 최고 온도",
                englishName: "System Maximum", group: .other, unit: .celsius,
                isSynthetic: true, sourceKeys: allTempKeys, aggregation: .maximum))
        }

        return result
    }
}
