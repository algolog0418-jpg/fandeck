//  SystemMonitor.swift — CPU / 메모리 / 프로세스 조회
//
//  온도만 보여주면 "왜 뜨거운지"를 알 수 없다. 무엇이 CPU 를 먹고 있는지까지
//  같은 화면에서 보여야 팬이 도는 이유를 납득할 수 있다.

import Foundation
import Darwin

public struct CPUUsage: Sendable, Hashable {
    public let user: Double
    public let system: Double
    public let idle: Double

    public var busy: Double { min(max(user + system, 0), 100) }

    public init(user: Double, system: Double, idle: Double) {
        self.user = user
        self.system = system
        self.idle = idle
    }
}

public struct MemoryUsage: Sendable, Hashable {
    public let total: UInt64
    public let used: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64
    /// 활성 상태 보기의 "앱 메모리" 에 해당한다.
    public var appMemory: UInt64 {
        used > wired + compressed ? used - wired - compressed : 0
    }
    /// macOS 의 "메모리 압박"에 해당하는 값(0~1).
    public let pressure: Double

    public init(total: UInt64, used: UInt64, wired: UInt64,
                compressed: UInt64, cached: UInt64, pressure: Double) {
        self.total = total
        self.used = used
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.pressure = pressure
    }

    public var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    public static func format(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1fGB", gb) }
        return String(format: "%.0fMB", Double(bytes) / 1_048_576)
    }
}

public struct ProcessEntry: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let user: String
    /// root 등 다른 사용자 소유 프로세스는 앱 권한으로 종료할 수 없다.
    public let isOwnedByCurrentUser: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64,
                user: String, isOwnedByCurrentUser: Bool) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.user = user
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
    }
}

public final class SystemMonitor: @unchecked Sendable {
    public static let shared = SystemMonitor()
    private init() {}

    // MARK: CPU
    //
    // CPU 사용률은 "지금까지 누적된 틱"으로만 얻을 수 있어서,
    // 직전에 읽은 값과의 차이로 계산해야 한다.

    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let cpuLock = NSLock()

    public func cpuUsage() -> CPUUsage {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPUUsage(user: 0, system: 0, idle: 100) }

        let user = UInt64(info.cpu_ticks.0)
        let nice = UInt64(info.cpu_ticks.3)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)

        cpuLock.lock(); defer { cpuLock.unlock() }
        defer { previousTicks = (user, system, idle, nice) }

        guard let prev = previousTicks else { return CPUUsage(user: 0, system: 0, idle: 100) }
        let dUser = Double(user &- prev.user) + Double(nice &- prev.nice)
        let dSystem = Double(system &- prev.system)
        let dIdle = Double(idle &- prev.idle)
        let total = dUser + dSystem + dIdle
        guard total > 0 else { return CPUUsage(user: 0, system: 0, idle: 100) }

        return CPUUsage(user: dUser / total * 100,
                        system: dSystem / total * 100,
                        idle: dIdle / total * 100)
    }

    // MARK: 메모리

    public func memoryUsage() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var totalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMemory, &size, nil, 0)

        guard result == KERN_SUCCESS else {
            return MemoryUsage(total: totalMemory, used: 0, wired: 0,
                               compressed: 0, cached: 0, pressure: 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        // 활성 상태 보기의 "앱 메모리"는 익명(internal) 페이지에서 언제든 버릴 수 있는
        // purgeable 을 뺀 값이다. active_count 를 쓰면 파일 캐시가 섞여 들어가 수치가 어긋난다.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appMemory = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize

        // 파일에서 다시 읽어올 수 있는 캐시는 "사용 중"으로 치지 않는다.
        let cached = UInt64(stats.external_page_count) * pageSize
        let used = appMemory + wired + compressed

        // 활성 상태 보기의 메모리 압박과 비슷하게, 압축·고정 메모리 비중으로 계산한다.
        let pressure = totalMemory > 0
            ? min(Double(wired + compressed) / Double(totalMemory) * 2.0, 1.0)
            : 0

        return MemoryUsage(total: totalMemory, used: used, wired: wired,
                           compressed: compressed, cached: cached, pressure: pressure)
    }

    // MARK: 프로세스
    //
    // 프로세스별 CPU 점유율을 직접 계산하려면 모든 프로세스의 스레드를 훑어야 해서
    // 비용이 크다. ps 한 번 호출이 훨씬 싸고, 계산 기준도 활성 상태 보기와 같다.

    /// 프로세스 하나가 실제로 차지하는 메모리.
    ///
    /// `ps` 의 RSS 는 공유 메모리를 중복으로 세서 활성 상태 보기와 값이 다르다.
    /// 활성 상태 보기가 "메모리" 열에 쓰는 값은 phys_footprint 이므로 그걸 읽는다.
    private func physicalFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// - Parameter displayNames: PID → 앱 표시 이름. GUI 앱은 실행 파일명(KakaoTalk)과
    ///   사용자에게 보이는 이름(카카오톡)이 달라서, 그대로 두면 한글로 검색해도 안 걸린다.
    ///   AppKit 이 없는 데몬에서도 쓸 수 있도록 매핑은 호출하는 쪽에서 넘겨받는다.
    /// - Parameter limit: 0 이면 전부 돌려준다.
    ///   화면에 몇 개를 보여줄지는 호출하는 쪽이 정한다. 여기서 미리 잘라내면
    ///   CPU 를 거의 안 쓰는 앱(카카오톡 등)이 순위 밖으로 밀려나
    ///   검색해도 목록에서 나타났다 사라졌다 한다.
    public func processes(limit: Int = 0, displayNames: [Int32: String] = [:]) -> [ProcessEntry] {
        let currentUID = getuid()
        let currentUserName = ProcessInfo.processInfo.userName

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,pcpu=,rss=,user=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [ProcessEntry] = []
        entries.reserveCapacity(256)

        for line in output.split(separator: "\n") {
            // pid pcpu rss user comm — comm 에는 공백이 들어갈 수 있으므로 앞 4개만 끊는다.
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }

            let user = String(parts[3])
            var name = String(parts[4]).trimmingCharacters(in: .whitespaces)
            // ps 는 실행 파일 전체 경로를 주므로 마지막 구성요소만 보여준다.
            if let slash = name.lastIndex(of: "/") {
                name = String(name[name.index(after: slash)...])
            }
            // GUI 앱이면 사용자에게 보이는 이름으로 바꾼다.
            if let display = displayNames[pid], !display.isEmpty { name = display }
            guard !name.isEmpty else { continue }

            entries.append(ProcessEntry(
                pid: pid,
                name: name,
                cpuPercent: cpu,
                memoryBytes: physicalFootprint(pid: pid) ?? (rssKB * 1024),
                user: user,
                isOwnedByCurrentUser: user == currentUserName || currentUID == 0))
        }

        let sorted = entries.sorted { $0.cpuPercent > $1.cpuPercent }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// 프로세스에 종료를 요청한다. 먼저 정상 종료(SIGTERM)를 보낸다.
    @discardableResult
    public func terminate(pid: Int32, force: Bool = false) -> Bool {
        kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}
