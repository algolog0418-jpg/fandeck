//  UpdateChecker.swift — 새 버전 확인
//
//  GitHub Releases 를 조회해 더 높은 버전이 있는지만 본다.
//  스스로 내려받아 설치하지는 않는다 — 팬을 제어하는 프로그램이 자기 자신을
//  말없이 바꿔치우는 건 바람직하지 않다. 알려주고 사용자가 받게 한다.

import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let owner = "algolog0418-jpg"
    private let repo = "fandeck"

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    func check(silent: Bool = false) {
        if !silent { state = .checking }
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = silent ? .idle : .failed(error.localizedDescription)
                    return
                }
                // 릴리스를 아직 하나도 올리지 않았으면 404 가 온다. 오류로 떠들 일은 아니다.
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    self.state = silent ? .idle : .upToDate
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.state = silent ? .idle : .failed("응답을 해석할 수 없습니다")
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (json["html_url"] as? String)
                    ?? "https://github.com/\(self.owner)/\(self.repo)/releases"

                if Self.isNewer(latest, than: self.currentVersion) {
                    self.state = .available(version: latest, url: page)
                } else {
                    self.state = silent ? .idle : .upToDate
                }
            }
        }.resume()
    }

    /// "1.2.10" 과 "1.2.9" 를 문자열로 비교하면 틀리므로 숫자 단위로 본다.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
