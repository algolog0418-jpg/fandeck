//  fandeckd — FanDeck 제어 데몬 (root)
//
//  SMC 쓰기는 root 만 가능하므로 실제 팬 제어는 전부 이 프로세스가 한다.
//  LaunchDaemon 으로 등록되어 로그인 전부터 돌고, 앱을 꺼도 설정한 커브가 유지된다.
//
//  데몬이 죽거나 종료될 때는 반드시 팬을 시스템 자동으로 되돌린다.
//  제어를 쥔 채 죽으면 고정 RPM 이 그대로 남아 과열로 이어질 수 있다.

import Foundation
import Darwin

let daemonVersion = BuildInfo.full

// MARK: - 로그

final class Log {
    static let shared = Log()
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "fandeck.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let path = FanDeckPaths.logFile
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    func write(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let line = "[\(self.formatter.string(from: Date()))] \(message)\n"
            if let data = line.data(using: .utf8) {
                self.handle?.write(data)
            }
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

func log(_ message: String) { Log.shared.write(message) }

// MARK: - 설정 저장소

final class ConfigStore {
    private let lock = NSLock()
    private var config: FanDeckConfig
    /// 설정이 바뀐 횟수. 앱이 이 번호로 변경을 알아챈다.
    private var revision = 0

    func currentRevision() -> Int {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    init(defaultFans: [FanInfo]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: FanDeckPaths.supportDirectory,
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        if let data = fm.contents(atPath: FanDeckPaths.configFile),
           let loaded = try? FanDeckConfig.decode(data) {
            config = loaded
            log("설정 파일을 불러왔습니다 (프로파일 \(loaded.profiles.count)개)")
            // 저장된 커브가 이 맥의 팬 범위를 벗어날 수 있다(다른 맥에서 만든 설정 등).
            if config.adapt(to: defaultFans) {
                log("팬 회전 범위에 맞게 커브를 조정했습니다 "
                    + defaultFans.map { "#\($0.index) \(Int($0.minRPM))~\(Int($0.maxRPM))rpm" }
                        .joined(separator: ", "))
            }
            // 새 버전에서 늘어난 설정 항목은 파일에 없다. 디코딩할 때 기본값으로 채워지지만
            // 그대로 두면 파일에는 계속 빠져 있어서, 앱에서 그 항목을 바꿔도
            // 저장된 적이 없는 것처럼 보인다. 불러오자마자 한 번 다시 써서 구조를 맞춘다.
            save()
        } else {
            config = FanDeckConfig.makeDefault(fans: defaultFans)
            log("설정 파일이 없어 기본 설정을 만들었습니다")
            save()
        }
    }

    func current() -> FanDeckConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    func update(_ newValue: FanDeckConfig) {
        lock.lock()
        config = newValue
        revision += 1
        lock.unlock()
        save()
    }

    func mutate(_ body: (inout FanDeckConfig) -> Void) {
        lock.lock()
        body(&config)
        revision += 1
        let snapshot = config
        lock.unlock()
        write(snapshot)
    }

    private func save() {
        lock.lock(); let snapshot = config; lock.unlock()
        write(snapshot)
    }

    private func write(_ snapshot: FanDeckConfig) {
        guard let data = try? snapshot.encoded() else { return }
        // 쓰다 말고 죽어도 설정이 깨지지 않도록 임시 파일에 쓰고 바꿔치운다.
        let tmp = FanDeckPaths.configFile + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: FanDeckPaths.configFile),
                                                      withItemAt: URL(fileURLWithPath: tmp))
            // 관리자 그룹이 읽을 수 있어야 앱에서 설정을 확인할 수 있다.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: FanDeckPaths.configFile)
        } catch {
            log("설정 저장 실패: \(error.localizedDescription)")
        }
    }
}

// MARK: - 실행 중인 프로세스 조회 (자동 프로파일 전환용)

enum ProcessScanner {
    /// 커널에서 프로세스 목록을 직접 가져온다. 데몬에는 NSWorkspace 가 없다.
    static func runningProcessNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let actual = size / MemoryLayout<kinfo_proc>.stride
        var names = Set<String>()
        for i in 0..<min(actual, procs.count) {
            var comm = procs[i].kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if !name.isEmpty { names.insert(name.lowercased()) }
        }
        return names
    }
}

// MARK: - 제어 루프

final class ControlLoop {
    private let smc = SMCService.shared
    private let fanController = FanController.shared
    private let store: ConfigStore
    private var engines: [Int: CurveEngine] = [:]
    private var descriptors: [String: SensorDescriptor] = [:]
    private var lastTick = Date()
    private let startedAt = Date()

    private let stateLock = NSLock()
    private var runtimeStates: [Int: FanRuntimeState] = [:]
    private var criticalFlag = false
    private var autoSwitchReason: String?
    /// 자동 전환이 끼어들기 전에 쓰고 있던 프로파일.
    /// 조건이 모두 풀리면 여기로 돌아간다.
    private var autoBaseProfileID: UUID?
    /// 자동으로 바뀐 프로파일에서 내려올 때 필요한 여유(°C).
    ///
    /// 조건이 65도이면 64.9도에서 바로 내려오는데, 온도는 그 근처에서 계속 오르내려서
    /// 프로파일이 쉴 새 없이 바뀌고 팬 소리도 함께 들썩인다. 올라갈 때보다
    /// 내려올 때 더 식어야 풀리도록 한다.
    private let releaseMargin: Double = 5
    /// 조건이 풀린 시각. 여기서부터 설정한 시간이 지나야 되돌린다.
    private var conditionsClearedAt: Date?
    /// 되돌리기까지 남은 시간(초). 화면에 보여 주기 위한 값.
    private var revertsIn: Double?
    private(set) var smcWritable = false
    /// 슬라이더로 임시 지정한 모드. 프로파일을 바꾸면 사라진다.
    private var overrides: [Int: FanMode] = [:]
    /// 상주하면서 계속 쌓는 시계열. 앱을 껐다 켜도 추이가 남아 있다.
    let history: HistoryBuffer

    init(store: ConfigStore, descriptors: [SensorDescriptor]) {
        self.store = store
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
        // 보관 시간 ÷ 틱 간격 만큼의 표본을 담을 수 있게 잡는다.
        let config = store.current()
        let slots = Int(config.historyRetentionSeconds / max(config.tickInterval, 0.5))
        self.history = HistoryBuffer(capacity: min(max(slots, 600), 60_000))
    }

    func checkWritable() {
        let fans = fanController.readAllFans()
        guard let first = fans.first else {
            log("팬을 찾지 못했습니다")
            smcWritable = false
            return
        }
        smcWritable = fanController.verifyWritable(first.index)
        log(smcWritable
            ? "SMC 팬 쓰기 확인 완료 — 제어 가능합니다"
            : "SMC 팬 쓰기가 반영되지 않습니다 — 자동 모드로만 동작합니다")
    }

    private func sensorValue(_ key: String) -> Double? {
        if let d = descriptors[key] { return smc.value(for: d) }
        return smc.read(key)
    }

    /// 자동 전환 규칙을 평가해 활성 프로파일을 바꾼다.
    private func evaluateAutoSwitch(config: inout FanDeckConfig) {
        guard config.autoSwitchEnabled else {
            // 자동 전환을 꺼 두면, 자동으로 바꿔 놨던 것도 원래대로 돌려준다.
            if let base = autoBaseProfileID {
                config.activeProfileID = base
                autoBaseProfileID = nil
                conditionsClearedAt = nil
                stateLock.lock(); revertsIn = nil; stateLock.unlock()
                log("자동 전환이 꺼져 원래 프로파일로 돌아갑니다")
            }
            if autoSwitchReason != nil {
                stateLock.lock(); autoSwitchReason = nil; stateLock.unlock()
            }
            return
        }
        var processNames: Set<String>?

        // 조건을 만족하는 후보를 모두 모은 뒤에 고른다.
        //
        // 예전에는 먼저 걸리는 하나를 그대로 썼는데, 우선순위가 모두 같으면
        // 정렬 순서가 정해져 있지 않아서 어느 것이 뽑힐지 알 수 없었다.
        // 온도 80도에서 "균형(65도 초과)" 과 "성능(75도 초과)" 이 둘 다 맞으면
        // 더 약한 쪽이 걸릴 수 있었고, 그만큼 덜 식는다.
        var candidates: [(profile: Profile, reason: String, threshold: Double, isApp: Bool)] = []

        for profile in config.profiles {
            switch profile.trigger {
            case .manual:
                continue

            case .appRunning(let names):
                if processNames == nil { processNames = ProcessScanner.runningProcessNames() }
                if let hit = names.first(where: { processNames!.contains($0.lowercased()) }) {
                    candidates.append((profile,
                                       L.t("\(hit) 실행 중", "\(hit) is running"),
                                       0, true))
                }

            case .sensorAbove(let key, let threshold):
                guard let value = sensorValue(key) else { continue }
                // 이미 이 프로파일로 바뀌어 있으면 조금 식었다고 바로 내려오지 않는다.
                let isCurrentlyAuto = autoBaseProfileID != nil && profile.id == config.activeProfileID
                let effective = isCurrentlyAuto ? threshold - releaseMargin : threshold
                if value > effective {
                    candidates.append((profile,
                                       "\(key) \(String(format: "%.0f", value))°C > \(Int(threshold))°C",
                                       threshold, false))
                }
            }
        }

        // 고르는 순서:
        //   1. 사용자가 정한 우선순위가 높은 것
        //   2. 앱 조건(사용자가 콕 집어 지정한 것)이 온도 조건보다 먼저
        //   3. 온도 조건끼리는 기준이 높은 쪽 — 더 뜨거울수록 더 센 설정으로 가야 한다
        let best: (Profile, String)? = candidates.max { a, b in
            if a.profile.priority != b.profile.priority {
                return a.profile.priority < b.profile.priority
            }
            if a.isApp != b.isApp { return !a.isApp && b.isApp }
            return a.threshold < b.threshold
        }.map { ($0.profile, $0.reason) }

        if let (profile, reason) = best {
            // 다시 조건이 맞았으니 되돌리기 대기는 없던 일로 한다.
            conditionsClearedAt = nil
            stateLock.lock(); revertsIn = nil; stateLock.unlock()
            // 처음 끼어드는 순간의 프로파일을 기억해 둔다. 나중에 여기로 돌아온다.
            if autoBaseProfileID == nil { autoBaseProfileID = config.activeProfileID }
            if config.activeProfileID != profile.id {
                config.activeProfileID = profile.id
                overrides.removeAll()
                engines.values.forEach { $0.reset() }
                log("자동 전환: \(profile.name) (\(reason))")
            }
            stateLock.lock(); autoSwitchReason = reason; stateLock.unlock()
        } else if let base = autoBaseProfileID {
            // 조건이 풀렸다. 다만 곧바로 되돌리지는 않는다.
            // 잠깐 식었을 뿐일 수 있어서, 식은 상태가 설정한 시간만큼 이어져야 되돌린다.
            let clearedAt = conditionsClearedAt ?? Date()
            conditionsClearedAt = clearedAt
            let waited = Date().timeIntervalSince(clearedAt)
            let delay = max(config.autoRevertDelaySeconds, 0)

            if waited >= delay {
                autoBaseProfileID = nil
                conditionsClearedAt = nil
                if config.activeProfileID != base {
                    config.activeProfileID = base
                    overrides.removeAll()
                    engines.values.forEach { $0.reset() }
                    let name = config.profiles.first { $0.id == base }?.name ?? "?"
                    log("조건이 풀린 지 \(Int(delay))초가 지나 원래 프로파일로 돌아갑니다: \(name)")
                }
                stateLock.lock(); autoSwitchReason = nil; revertsIn = nil; stateLock.unlock()
            } else {
                let remaining = delay - waited
                stateLock.lock(); revertsIn = remaining; stateLock.unlock()
            }
        } else {
            conditionsClearedAt = nil
            stateLock.lock(); autoSwitchReason = nil; revertsIn = nil; stateLock.unlock()
        }
    }

    func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now

        var config = store.current()
        let previousID = config.activeProfileID
        evaluateAutoSwitch(config: &config)
        if config.activeProfileID != previousID {
            store.update(config)
        }

        guard let profile = config.activeProfile else { return }
        let fans = fanController.readAllFans()
        var newStates: [Int: FanRuntimeState] = [:]
        var anyCritical = false

        for fan in fans {
            let engine = engines[fan.index] ?? {
                let e = CurveEngine()
                engines[fan.index] = e
                return e
            }()

            var setting = profile.setting(for: fan.index)
            if let override = overrides[fan.index] {
                setting = FanSetting(fanIndex: fan.index, mode: override)
            }

            let decision = engine.decide(setting: setting, fan: fan,
                                         smoothing: profile.smoothing,
                                         safety: config.safety,
                                         readSensor: { [weak self] in self?.sensorValue($0) },
                                         elapsed: elapsed)
            if decision.isCritical { anyCritical = true }

            if let target = decision.targetRPM {
                if smcWritable {
                    // 매 틱 다시 쓴다. thermalmonitord 가 값을 되돌리는 모델이 있어
                    // 한 번 쓰고 마는 방식은 신뢰할 수 없다.
                    do { _ = try fanController.setTarget(fan.index, rpm: target) }
                    catch { log("팬 \(fan.index) 쓰기 실패: \(error)") }
                }
            } else if case .automatic = setting.mode {
                // 자동으로 바뀐 직후 한 번만 시스템에 돌려주면 된다.
                if runtimeStates[fan.index]?.appliedRPM != nil, smcWritable {
                    try? fanController.setAutomatic(fan.index)
                    log("팬 \(fan.index) 를 시스템 자동 제어로 되돌렸습니다")
                }
            }

            newStates[fan.index] = FanRuntimeState(
                fanIndex: fan.index,
                appliedRPM: decision.targetRPM,
                effectiveTemperature: decision.effectiveTemperature,
                modeLabel: decision.isCritical ? "과열 보호" : setting.mode.label)
        }

        stateLock.lock()
        runtimeStates = newStates
        criticalFlag = anyCritical
        stateLock.unlock()

        recordHistory(config: config, fans: fans)
    }

    /// 기록 대상 센서만 골라 한 표본으로 남긴다. 전부 기록하면 표본 하나가 174개 값이 되어
    /// 메모리와 전송량이 과해진다.
    private func recordHistory(config: FanDeckConfig, fans: [FanInfo]) {
        var keys = Set(config.historySensorKeys)
        keys.formUnion(config.favoriteSensorKeys)
        if case .curve(let curve)? = config.activeProfile?.fanSettings.first?.mode {
            keys.insert(curve.sensorKey)
        }
        keys.insert(config.safety.sensorKey)
        keys.insert(config.menuBarSensorKey)

        var values: [String: Double] = [:]
        values.reserveCapacity(keys.count)
        for key in keys {
            if let v = sensorValue(key) { values[key] = v }
        }
        var rpm: [Int: Double] = [:]
        for fan in fans { rpm[fan.index] = fan.currentRPM }

        history.append(HistorySample(timestamp: Date().timeIntervalSince1970,
                                     values: values, fanRPM: rpm))
    }

    func snapshot() -> StatusSnapshot {
        let config = store.current()
        stateLock.lock()
        let states = Array(runtimeStates.values).sorted { $0.fanIndex < $1.fanIndex }
        let critical = criticalFlag
        let reason = autoSwitchReason
        let reverts = revertsIn
        stateLock.unlock()

        return StatusSnapshot(
            daemonVersion: daemonVersion,
            uptimeSeconds: Date().timeIntervalSince(startedAt),
            activeProfileID: config.activeProfileID,
            activeProfileName: config.activeProfile?.name ?? "알 수 없음",
            isCritical: critical,
            smcWritable: smcWritable,
            fans: fanController.readAllFans(),
            runtime: states,
            autoSwitchReason: reason,
            configRevision: store.currentRevision(),
            configSchema: FanDeckConfig.schemaVersion,
            revertsInSeconds: reverts)
    }

    func setOverride(fanIndex: Int, mode: FanMode) {
        overrides[fanIndex] = mode
        engines[fanIndex]?.reset()
    }

    func clearOverrides() {
        overrides.removeAll()
        engines.values.forEach { $0.reset() }
    }

    /// 사용자가 직접 프로파일을 골랐을 때 부른다.
    /// 그 선택이 새 기준이 되어야, 조건이 풀렸을 때 엉뚱한 프로파일로 돌아가지 않는다.
    func forgetAutoBase() {
        autoBaseProfileID = nil
        conditionsClearedAt = nil
        stateLock.lock(); revertsIn = nil; stateLock.unlock()
    }

    /// 모든 팬을 시스템 자동으로 돌려놓는다. 종료 경로에서 반드시 호출된다.
    func releaseAll() {
        guard smcWritable else { return }
        for fan in fanController.readAllFans() {
            try? fanController.setAutomatic(fan.index)
        }
        log("모든 팬을 시스템 자동 제어로 반환했습니다")
    }
}

// MARK: - 소켓 서버

final class SocketServer {
    private let path: String
    private let handler: (IPCRequest) -> IPCResponse
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "fandeck.socket")

    init(path: String, handler: @escaping (IPCRequest) -> IPCResponse) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw IPCError.daemonUnavailable }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            log("소켓 bind 실패: \(String(cString: strerror(errno)))")
            throw IPCError.daemonUnavailable
        }
        guard listen(listenFD, 16) == 0 else { throw IPCError.daemonUnavailable }

        // root:admin 0660 — 관리자 계정만 제어할 수 있게 한다.
        chmod(path, 0o660)
        let adminGID: gid_t = {
            guard let group = getgrnam("admin") else { return 80 }
            return group.pointee.gr_gid
        }()
        chown(path, 0, adminGID)

        queue.async { [weak self] in self?.acceptLoop() }
        log("소켓 서버 시작: \(path)")
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            handleClient(client)
            Darwin.close(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        // 요청은 한 줄짜리 JSON 이다. 개행이 나올 때까지만 읽는다.
        while !buffer.contains(0x0A) {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 1_000_000 { return }   // 비정상적으로 큰 입력 차단
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return }
        let line = buffer[buffer.startIndex..<newline]

        let response: IPCResponse
        if let request = try? JSONDecoder().decode(IPCRequest.self, from: line) {
            response = handler(request)
        } else {
            response = .failure("요청을 해석할 수 없습니다")
        }

        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    func stop() {
        if listenFD >= 0 { Darwin.close(listenFD) }
        unlink(path)
    }
}

// MARK: - 진입점

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("fandeckd 는 root 로 실행해야 합니다.\n".utf8))
    exit(1)
}

log("fandeckd \(BuildInfo.version) (빌드 \(BuildInfo.build), \(BuildInfo.date)) 시작")

do {
    try SMCService.shared.open()
} catch {
    log("AppleSMC 를 열 수 없습니다: \(error)")
    exit(1)
}

let availableKeys = Set((try? SMCService.shared.allKeys()) ?? [])
let descriptors = SensorCatalog.build(availableKeys: availableKeys)
log("센서 \(descriptors.count)개 인식 (SMC 키 \(availableKeys.count)개)")

let initialFans = FanController.shared.readAllFans()
log("팬 \(initialFans.count)개: " + initialFans.map {
    "#\($0.index) \($0.currentRPM.rounded())rpm (\($0.minRPM.rounded())~\($0.maxRPM.rounded()))"
}.joined(separator: ", "))

let store = ConfigStore(defaultFans: initialFans)
let loop = ControlLoop(store: store, descriptors: descriptors)
loop.checkWritable()

let server = SocketServer(path: FanDeckPaths.socketPath) { request in
    switch request {
    case .ping:
        return .pong(version: daemonVersion)
    case .status:
        return .status(loop.snapshot())
    case .getConfig:
        return .config(store.current())
    case .setConfig(let newConfig):
        let previousInterval = store.current().tickInterval
        store.update(newConfig)
        loop.clearOverrides()
        // 제어 주기가 바뀌었으면 타이머를 다시 걸어야 반영된다.
        if abs(previousInterval - newConfig.tickInterval) > 0.01 {
            rescheduleTimer(interval: newConfig.tickInterval)
            log("제어 주기 변경: \(newConfig.tickInterval)초")
        }
        log("설정이 갱신되었습니다")
        return .ok
    case .activateProfile(let id):
        var config = store.current()
        guard config.profiles.contains(where: { $0.id == id }) else {
            return .failure("그런 프로파일이 없습니다")
        }
        config.activeProfileID = id
        store.update(config)
        loop.forgetAutoBase()
        loop.clearOverrides()
        log("프로파일 전환: \(config.activeProfile?.name ?? "?")")
        return .ok
    case .setFanMode(let index, let mode):
        loop.setOverride(fanIndex: index, mode: mode)
        return .ok
    case .verifyWritable:
        loop.checkWritable()
        return .writable(loop.smcWritable)
    case .releaseAll:
        loop.clearOverrides()
        loop.releaseAll()
        return .ok
    case .history(let sinceSeconds, let maxCount):
        let since = sinceSeconds.map { Date().timeIntervalSince1970 - $0 }
        return .history(loop.history.samples(since: since, maxCount: maxCount ?? 1200))
    }
}

do { try server.start() } catch {
    log("소켓 서버를 시작할 수 없습니다: \(error)")
    exit(1)
}

func rescheduleTimer(interval: Double) {
    timer.cancel()
    timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + interval, repeating: max(interval, 0.25))
    timer.setEventHandler { loop.tick() }
    timer.resume()
}

// 종료 시 팬 제어를 반드시 시스템에 돌려준다.
// DispatchSource 는 참조가 끊기면 동작을 멈추므로 전역에 붙잡아 둔다.
var signalSources: [DispatchSourceSignal] = []
var shuttingDown = false
func shutdown(_ reason: String) {
    guard !shuttingDown else { return }
    shuttingDown = true
    log("종료 요청(\(reason)) — 팬 제어를 반환합니다")
    loop.releaseAll()
    server.stop()
    // 로그가 디스크에 닿을 시간을 준다.
    Thread.sleep(forTimeInterval: 0.2)
    exit(0)
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { shutdown("signal \(sig)") }
    source.resume()
    // 소스가 해제되지 않도록 붙잡아 둔다.
    signalSources.append(source)
}

var timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1.0, repeating: store.current().tickInterval)
timer.setEventHandler { loop.tick() }
timer.resume()

log("제어 루프 시작 (주기 \(store.current().tickInterval)초)")
dispatchMain()
