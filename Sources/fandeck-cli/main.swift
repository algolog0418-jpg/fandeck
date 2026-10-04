//  fandeck — 터미널용 CLI
//
//  센서 읽기는 데몬 없이도 되고, 팬 제어는 데몬에 요청한다.
//  GUI 를 켜지 않고 스크립트에서 쓰거나, 설치가 제대로 됐는지 확인할 때 쓴다.

import Foundation

let version = "1.0.0"

// MARK: 터미널 꾸미기

enum Ansi {
    static let isTTY = isatty(STDOUT_FILENO) == 1
    static func wrap(_ code: String, _ text: String) -> String {
        isTTY ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }
    static func bold(_ t: String) -> String { wrap("1", t) }
    static func dim(_ t: String) -> String { wrap("2", t) }
    static func cyan(_ t: String) -> String { wrap("36", t) }
    static func green(_ t: String) -> String { wrap("32", t) }
    static func yellow(_ t: String) -> String { wrap("33", t) }
    static func red(_ t: String) -> String { wrap("31", t) }

    /// 온도에 따라 색을 고른다. 눈으로 바로 위험도를 알 수 있게.
    static func forTemperature(_ t: Double) -> (String) -> String {
        switch t {
        case ..<55: return green
        case ..<70: return cyan
        case ..<85: return yellow
        default:    return red
        }
    }

    static func bar(_ fraction: Double, width: Int = 20) -> String {
        let filled = Int((max(0, min(1, fraction)) * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((Ansi.red("오류: ") + message + "\n").utf8))
    exit(1)
}

// MARK: 공통 준비

let smc = SMCService.shared
func loadDescriptors() -> [SensorDescriptor] {
    guard (try? smc.open()) != nil else { fail("AppleSMC 를 열 수 없습니다.") }
    let keys = Set((try? smc.allKeys()) ?? [])
    return SensorCatalog.build(availableKeys: keys)
}

func requestDaemon(_ request: IPCRequest) -> IPCResponse {
    do { return try IPCClient.send(request) }
    catch { fail("\(error)") }
}

// MARK: 명령 구현

func cmdStatus() {
    let descriptors = loadDescriptors()
    let byKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })

    print(Ansi.bold("\n  FanDeck \(version)"))

    // 데몬이 없어도 센서는 보여준다.
    var snapshot: StatusSnapshot?
    if case .status(let s) = (try? IPCClient.send(.status)) { snapshot = s }

    if let s = snapshot {
        let state = s.smcWritable ? Ansi.green("켜짐") : Ansi.yellow("속도 변경 불가")
        print("  팬 제어 \(state) · 모드 " + Ansi.cyan(s.activeProfileName))
        if s.isCritical { print("  " + Ansi.red("과열 보호 작동 중 — 팬 최대 속도")) }
        if let reason = s.autoSwitchReason { print("  " + Ansi.dim("자동 전환: \(reason)")) }
    } else {
        print("  " + Ansi.yellow("팬 제어가 꺼져 있습니다 (온도 보기만 가능)"))
    }

    print(Ansi.bold("\n  팬"))
    let fans = snapshot?.fans ?? FanController.shared.readAllFans()
    for fan in fans {
        let db = NoiseEstimator.estimatedDB(rpm: fan.currentRPM, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
        let runtime = snapshot?.runtime.first { $0.fanIndex == fan.index }
        let mode = runtime?.modeLabel ?? "—"
        print(String(format: "  %@  %@ %5.0f rpm  %@  %@",
                     Ansi.cyan(fan.name.padding(toLength: 8, withPad: " ", startingAt: 0)),
                     Ansi.bar(fan.loadFraction),
                     fan.currentRPM,
                     Ansi.dim("\(Int(fan.minRPM))~\(Int(fan.maxRPM))"),
                     Ansi.dim("\(mode) · 체감 \(Int(db))dB \(NoiseEstimator.label(forDB: db))")))
    }

    print(Ansi.bold("\n  주요 온도"))
    let highlights = [SensorCatalog.cpuMaxKey, SensorCatalog.cpuAverageKey,
                      SensorCatalog.gpuMaxKey, SensorCatalog.systemMaxKey, "PSTR"]
    for key in highlights {
        guard let d = byKey[key], let v = smc.value(for: d) else { continue }
        let color = d.unit == .celsius ? Ansi.forTemperature(v) : { Ansi.cyan($0) }
        print(String(format: "  %@ %@",
                     d.name.padding(toLength: 18, withPad: " ", startingAt: 0),
                     color(String(format: "%.1f%@", v, d.unit.suffix))))
    }
    print("")
}

func cmdSensors(_ filter: String?) {
    let descriptors = loadDescriptors()
    let grouped = Dictionary(grouping: descriptors) { $0.group }

    for group in SensorGroup.allCases {
        guard var items = grouped[group] else { continue }
        if let filter, !filter.isEmpty {
            let f = filter.lowercased()
            items = items.filter {
                $0.name.lowercased().contains(f) || $0.key.lowercased().contains(f)
                || $0.englishName.lowercased().contains(f)
            }
        }
        guard !items.isEmpty else { continue }
        print("\n" + Ansi.bold("  " + group.localizedName))
        for d in items.sorted(by: { $0.name < $1.name }) {
            guard let v = smc.value(for: d) else { continue }
            let color = d.unit == .celsius ? Ansi.forTemperature(v) : { Ansi.cyan($0) }
            print(String(format: "    %@ %@ %@",
                         Ansi.dim(d.key.padding(toLength: 8, withPad: " ", startingAt: 0)),
                         d.name.padding(toLength: 24, withPad: " ", startingAt: 0),
                         color(String(format: "%.\(d.unit.fractionDigits)f%@", v, d.unit.suffix))))
        }
    }
    print("")
}

func cmdSet(_ argument: String) {
    let fans = FanController.shared.readAllFans()
    guard let fan = fans.first else { fail("팬을 찾을 수 없습니다.") }

    let mode: FanMode
    switch argument.lowercased() {
    case "auto", "자동":
        mode = .automatic
    case "max", "최대":
        mode = .fixed(rpm: fan.maxRPM)
    case "min", "최소":
        mode = .fixed(rpm: fan.minRPM)
    default:
        guard let rpm = Double(argument) else {
            fail("RPM 숫자나 auto/max/min 중 하나를 지정하세요.")
        }
        guard rpm >= fan.minRPM - 1, rpm <= fan.maxRPM + 1 else {
            fail("이 팬의 범위는 \(Int(fan.minRPM))~\(Int(fan.maxRPM)) rpm 입니다.")
        }
        mode = .fixed(rpm: rpm)
    }

    for f in fans {
        _ = requestDaemon(.setFanMode(fanIndex: f.index, mode: mode))
    }
    print(Ansi.green("  적용됨: ") + mode.label)
}

func cmdProfile(_ name: String?) {
    guard case .config(let config) = requestDaemon(.getConfig) else { fail("설정을 가져올 수 없습니다.") }

    guard let name else {
        print(Ansi.bold("\n  프로파일"))
        for p in config.profiles {
            let marker = p.id == config.activeProfileID ? Ansi.green(" ●") : "  "
            let trigger = p.trigger.label == "수동" ? "" : Ansi.dim("  [\(p.trigger.label)]")
            print("\(marker) \(p.name)\(trigger)")
        }
        print("")
        return
    }

    guard let target = config.profiles.first(where: { $0.name == name })
        ?? config.profiles.first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) else {
        fail("'\(name)' 프로파일이 없습니다.")
    }
    _ = requestDaemon(.activateProfile(target.id))
    print(Ansi.green("  프로파일 전환: ") + target.name)
}

func cmdWatch(interval: Double) {
    let descriptors = loadDescriptors()
    let byKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
    let keys = [SensorCatalog.cpuMaxKey, SensorCatalog.gpuMaxKey, "PSTR"]

    print(Ansi.dim("  Ctrl+C 로 종료\n"))
    while true {
        var parts: [String] = []
        for fan in FanController.shared.readAllFans() {
            let db = NoiseEstimator.estimatedDB(rpm: fan.currentRPM, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
            parts.append(String(format: "%@ %4.0frpm %@",
                                Ansi.bar(fan.loadFraction, width: 12),
                                fan.currentRPM, Ansi.dim("\(Int(db))dB")))
        }
        for key in keys {
            guard let d = byKey[key], let v = smc.value(for: d) else { continue }
            let color = d.unit == .celsius ? Ansi.forTemperature(v) : { Ansi.cyan($0) }
            parts.append(color(String(format: "%@ %.1f%@", d.name, v, d.unit.suffix)))
        }
        let line = "  " + parts.joined(separator: Ansi.dim("  │  "))
        // 한 줄을 계속 덮어쓴다.
        print("\u{001B}[2K\r" + line, terminator: "")
        fflush(stdout)
        Thread.sleep(forTimeInterval: interval)
    }
}

func cmdExport(_ path: String, hours: Double) {
    guard case .history(let samples) = requestDaemon(.history(sinceSeconds: hours * 3600, maxCount: 100_000)) else {
        fail("기록을 가져올 수 없습니다.")
    }
    guard !samples.isEmpty else { fail("기록이 아직 없습니다. 데몬이 켜진 지 얼마나 됐는지 확인하세요.") }

    let descriptors = loadDescriptors()
    let byKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
    let sensorKeys = Array(Set(samples.flatMap { $0.values.keys })).sorted()
    let fanIndices = Array(Set(samples.flatMap { $0.fanRPM.keys })).sorted()

    var csv = "시각," + sensorKeys.map { byKey[$0]?.name ?? $0 }.joined(separator: ",")
    if !fanIndices.isEmpty {
        csv += "," + fanIndices.map { "팬\($0) RPM" }.joined(separator: ",")
    }
    csv += "\n"

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    for s in samples {
        var row = [formatter.string(from: s.date)]
        row += sensorKeys.map { s.values[$0].map { String(format: "%.2f", $0) } ?? "" }
        row += fanIndices.map { s.fanRPM[$0].map { String(format: "%.0f", $0) } ?? "" }
        csv += row.joined(separator: ",") + "\n"
    }

    do {
        // 엑셀이 한글을 깨뜨리지 않도록 BOM 을 붙인다.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(csv.utf8))
        try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        print(Ansi.green("  내보냄: ") + path + Ansi.dim(" (\(samples.count)개 표본)"))
    } catch {
        fail("파일을 쓸 수 없습니다: \(error.localizedDescription)")
    }
}

func cmdHelp() {
    print("""

      \(Ansi.bold("FanDeck \(version)")) — 맥 온도 모니터링 / 팬 제어

      \(Ansi.bold("사용법"))
        fandeck status                현재 상태 요약
        fandeck sensors [검색어]       센서 전체 목록
        fandeck set <rpm|auto|max|min> 팬 속도 지정
        fandeck profile [이름]         프로파일 목록 / 전환
        fandeck watch [주기초]         실시간 한 줄 모니터
        fandeck export <파일.csv> [시간] 기록을 CSV 로 저장 (기본 6시간)
        fandeck verify                SMC 쓰기가 되는지 진단
        fandeck release               모든 팬을 시스템 자동으로 복귀

      \(Ansi.dim("팬 속도 변경은 앱에서 '팬 제어 켜기'를 한 번 눌러야 됩니다. 온도 보기는 그냥 됩니다."))

    """)
}

// MARK: 디스패치

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil, "status":
    cmdStatus()
case "sensors":
    cmdSensors(args.count > 1 ? args[1] : nil)
case "set":
    guard args.count > 1 else { fail("RPM 이나 auto/max/min 을 지정하세요.") }
    cmdSet(args[1])
case "profile":
    cmdProfile(args.count > 1 ? args[1...].joined(separator: " ") : nil)
case "watch":
    cmdWatch(interval: args.count > 1 ? (Double(args[1]) ?? 1.0) : 1.0)
case "export":
    guard args.count > 1 else { fail("저장할 파일 경로를 지정하세요.") }
    cmdExport(args[1], hours: args.count > 2 ? (Double(args[2]) ?? 6) : 6)
case "verify":
    if case .writable(let ok) = requestDaemon(.verifyWritable) {
        print(ok ? Ansi.green("  SMC 팬 쓰기 정상 — 제어할 수 있습니다.")
                 : Ansi.yellow("  SMC 팬 쓰기가 반영되지 않습니다. 다른 팬 제어 앱이 실행 중인지 확인하세요."))
    }
case "release":
    _ = requestDaemon(.releaseAll)
    print(Ansi.green("  모든 팬을 시스템 자동 제어로 되돌렸습니다."))
case "version", "--version", "-v":
    print("FanDeck \(version)")
case "help", "--help", "-h":
    cmdHelp()
default:
    fail("알 수 없는 명령: \(args[0])  (fandeck help 참고)")
}
