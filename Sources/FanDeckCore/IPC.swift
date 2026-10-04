//  IPC.swift — 앱/CLI 와 root 데몬 사이의 통신
//
//  유닉스 도메인 소켓(/var/run/fandeck.sock)에 개행으로 끊어진 JSON 한 줄씩 주고받는다.
//  소켓은 root:admin 0660 으로 만들어서 관리자 계정만 제어할 수 있게 한다.
//  센서 읽기는 권한이 필요 없으므로 앱이 직접 SMC 를 읽고, 소켓은 "쓰기"와
//  데몬만 아는 제어 상태를 가져올 때만 쓴다.

import Foundation
import Darwin

public struct FanRuntimeState: Codable, Hashable, Sendable {
    public let fanIndex: Int
    /// 데몬이 마지막으로 SMC 에 쓴 값. nil 이면 시스템 자동에 맡긴 상태.
    public let appliedRPM: Double?
    /// 히스테리시스까지 반영한 제어 입력 온도.
    public let effectiveTemperature: Double?
    public let modeLabel: String

    public init(fanIndex: Int, appliedRPM: Double?, effectiveTemperature: Double?, modeLabel: String) {
        self.fanIndex = fanIndex
        self.appliedRPM = appliedRPM
        self.effectiveTemperature = effectiveTemperature
        self.modeLabel = modeLabel
    }
}

public struct StatusSnapshot: Codable, Hashable, Sendable {
    public let daemonVersion: String
    public let uptimeSeconds: Double
    public let activeProfileID: UUID
    public let activeProfileName: String
    public let isCritical: Bool
    /// SMC 쓰기가 실제로 먹히는지 데몬이 시작 시 확인한 결과.
    public let smcWritable: Bool
    public let fans: [FanInfo]
    public let runtime: [FanRuntimeState]
    /// 데몬이 자동 전환으로 프로파일을 바꿨다면 그 이유.
    public let autoSwitchReason: String?

    public init(daemonVersion: String, uptimeSeconds: Double, activeProfileID: UUID,
                activeProfileName: String, isCritical: Bool, smcWritable: Bool,
                fans: [FanInfo], runtime: [FanRuntimeState], autoSwitchReason: String?) {
        self.daemonVersion = daemonVersion
        self.uptimeSeconds = uptimeSeconds
        self.activeProfileID = activeProfileID
        self.activeProfileName = activeProfileName
        self.isCritical = isCritical
        self.smcWritable = smcWritable
        self.fans = fans
        self.runtime = runtime
        self.autoSwitchReason = autoSwitchReason
    }
}

public enum IPCRequest: Codable, Sendable {
    case ping
    case status
    case getConfig
    case setConfig(FanDeckConfig)
    case activateProfile(UUID)
    /// 활성 프로파일을 건드리지 않고 팬 하나만 임시로 바꾼다(UI 슬라이더용).
    case setFanMode(fanIndex: Int, mode: FanMode)
    case verifyWritable
    /// 모든 팬을 시스템 자동으로 되돌린다.
    case releaseAll
    /// 데몬이 쌓아둔 시계열을 가져온다. sinceSeconds 는 "최근 N초", maxCount 는 솎아낼 상한.
    case history(sinceSeconds: Double?, maxCount: Int?)
}

public enum IPCResponse: Codable, Sendable {
    case pong(version: String)
    case status(StatusSnapshot)
    case config(FanDeckConfig)
    case ok
    case writable(Bool)
    case history([HistorySample])
    case failure(String)
}

public enum IPCError: Error, CustomStringConvertible {
    case daemonUnavailable
    case timeout
    case malformedResponse
    case remote(String)

    public var description: String {
        switch self {
        case .daemonUnavailable: return "FanDeck 데몬에 연결할 수 없습니다. 설치되어 실행 중인지 확인하세요."
        case .timeout:           return "데몬 응답이 없습니다."
        case .malformedResponse: return "데몬 응답을 해석할 수 없습니다."
        case .remote(let m):     return m
        }
    }
}

/// 요청 하나마다 연결을 새로 여는 단순한 동기 클라이언트.
/// 주고받는 양이 작아서 연결 유지로 얻을 이득이 없고, 데몬 재시작에도 자동으로 복구된다.
public enum IPCClient {

    public static func send(_ request: IPCRequest,
                            socketPath: String = FanDeckPaths.socketPath,
                            timeout: TimeInterval = 3.0) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.daemonUnavailable }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.daemonUnavailable
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw IPCError.daemonUnavailable }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)  // 개행으로 메시지 끝을 알린다
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { throw IPCError.daemonUnavailable }
                sent += n
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { throw IPCError.timeout }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { throw IPCError.malformedResponse }
        let line = buffer[buffer.startIndex..<newline]
        guard let response = try? JSONDecoder().decode(IPCResponse.self, from: line) else {
            throw IPCError.malformedResponse
        }
        if case .failure(let message) = response { throw IPCError.remote(message) }
        return response
    }

    public static var isDaemonRunning: Bool {
        guard FileManager.default.fileExists(atPath: FanDeckPaths.socketPath) else { return false }
        return (try? send(.ping, timeout: 1.0)) != nil
    }
}
