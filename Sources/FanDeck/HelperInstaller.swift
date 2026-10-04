//  HelperInstaller.swift — 팬 제어 기능 켜기
//
//  팬 속도를 바꾸려면 macOS 가 관리자 권한을 요구한다. 터미널을 열게 하는 대신,
//  앱 안에서 버튼을 누르면 macOS 표준 암호 창이 뜨고 끝나도록 만든다.
//  설치되는 것은 백그라운드에서 팬을 지켜보는 작은 프로그램 하나다.

import Foundation
import AppKit

@MainActor
final class HelperInstaller: ObservableObject {
    static let shared = HelperInstaller()

    enum State: Equatable {
        case idle
        case installing
        case success
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    var isInstalling: Bool { state == .installing }

    /// 앱 번들 안에 들어 있는 설치 스크립트와 실행 파일들.
    private var resourcesDirectory: URL? {
        Bundle.main.resourceURL
    }

    var canInstall: Bool {
        guard let dir = resourcesDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("fandeckd").path)
    }

    func install(completion: @escaping (Bool) -> Void) {
        guard let dir = resourcesDirectory else {
            state = .failed("앱 구성 파일을 찾을 수 없습니다.")
            completion(false)
            return
        }
        state = .installing

        let script = dir.appendingPathComponent("setup-helper.sh").path
        // 경로에 한글이나 공백이 들어가도 깨지지 않도록 따옴표로 감싼다.
        let command = "'\(script)' '\(dir.path)'"
        let appleScript = """
        do shell script "\(command.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\""))" \
        with administrator privileges
        """

        // NSAppleScript 는 메인 스레드를 막으므로 백그라운드에서 돌린다.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: appleScript)?.executeAndReturnError(&error)

            DispatchQueue.main.async {
                if let error {
                    let number = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                    // -128 은 사용자가 암호 창에서 취소를 누른 경우다. 실패로 떠들 필요가 없다.
                    if number == -128 {
                        self.state = .idle
                    } else {
                        let message = error["NSAppleScriptErrorMessage"] as? String
                            ?? "설치에 실패했습니다."
                        self.state = .failed(message)
                    }
                    completion(false)
                } else {
                    _ = result
                    self.state = .success
                    completion(true)
                }
            }
        }
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        guard let dir = resourcesDirectory else { completion(false); return }
        let script = dir.appendingPathComponent("remove-helper.sh").path
        let appleScript = """
        do shell script "'\(script)'" with administrator privileges
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            _ = NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                self.state = error == nil ? .idle : .failed("제거에 실패했습니다.")
                completion(error == nil)
            }
        }
    }
}
