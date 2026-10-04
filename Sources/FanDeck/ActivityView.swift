//  ActivityView.swift — CPU / 메모리 / 프로세스
//
//  팬이 왜 도는지 알려면 온도만으로는 부족하다. 무엇이 CPU 를 먹고 있는지까지
//  같은 앱에서 보여야, 보고 바로 끌 수 있다.

import SwiftUI
import Charts

private final class ActivityState: ObservableObject {
    enum SortKey: String, CaseIterable { case cpu, memory, name

        var title: String {
            switch self {
            case .cpu:    return "CPU"
            case .memory: return "메모리"
            case .name:   return "이름"
            }
        }
    }

    @Published var sortKey: SortKey = .cpu
    @Published var search = ""
    @Published var confirmingKill: ProcessEntry?
}

struct ActivityView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = ActivityState()

    /// 한 번에 그릴 행 수. 전체(보통 600개 넘는다)를 다 그리면 화면이 버벅인다.
    /// 검색 중에는 제한하지 않는다 — 찾는 프로세스가 잘려 나가면 안 된다.
    private static let visibleLimit = 200

    private var isSearching: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filtered: [ProcessEntry] {
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = model.processes
        if !query.isEmpty {
            // 표시 이름과 PID 모두로 찾는다. 한글 이름도 여기서 걸린다.
            list = list.filter { $0.name.lowercased().contains(query) || String($0.pid).contains(query) }
        }
        switch ui.sortKey {
        case .cpu:    list.sort { $0.cpuPercent > $1.cpuPercent }
        case .memory: list.sort { $0.memoryBytes > $1.memoryBytes }
        case .name:   list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return isSearching ? list : Array(list.prefix(Self.visibleLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow
            Divider()
            processToolbar
            Divider()
            processList
        }
        .onAppear { model.needsProcessList = true }
        .onDisappear { model.needsProcessList = false }
        .alert("프로세스를 종료할까요?",
               isPresented: Binding(get: { ui.confirmingKill != nil },
                                    set: { if !$0 { ui.confirmingKill = nil } })) {
            Button("취소", role: .cancel) { ui.confirmingKill = nil }
            Button("종료", role: .destructive) {
                if let target = ui.confirmingKill { model.terminate(target) }
                ui.confirmingKill = nil
            }
        } message: {
            if let target = ui.confirmingKill {
                Text("\(target.name) (PID \(target.pid)) 에 종료를 요청합니다.\n저장하지 않은 작업이 있으면 사라질 수 있습니다.")
            }
        }
    }

    // MARK: 상단 요약

    private var summaryRow: some View {
        HStack(spacing: Theme.gridSpacing) {
            cpuCard
            memoryCard
            thermalCard
        }
        .padding(Theme.gridSpacing)
    }

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("CPU 사용률").font(Theme.label).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.0f", model.cpuUsage.busy))
                    .font(Theme.numeric(28, weight: .semibold))
                Text("%").font(Theme.numeric(13)).foregroundStyle(.secondary)
            }

            // 사용자/시스템 비중을 한 막대에 겹쳐 보여준다.
            GeometryReader { geo in
                HStack(spacing: 1) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * model.cpuUsage.user / 100)
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: geo.size.width * model.cpuUsage.system / 100)
                    Rectangle().fill(Color.primary.opacity(0.08))
                }
                .clipShape(Capsule())
                .animation(.easeOut(duration: 0.4), value: model.cpuUsage.busy)
            }
            .frame(height: 7)

            HStack(spacing: 12) {
                legend(color: .accentColor, label: "사용자", value: model.cpuUsage.user)
                legend(color: .orange, label: "시스템", value: model.cpuUsage.system)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: .accentColor)
    }

    private func legend(color: Color, label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", value)).font(Theme.numeric(10))
        }
    }

    private var memoryCard: some View {
        let memory = model.memoryUsage
        let pressureColor: Color = memory.pressure > 0.75 ? .red
                                 : memory.pressure > 0.5 ? .orange : .green
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "memorychip").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pressureColor)
                Text("메모리").font(Theme.label).foregroundStyle(.secondary)
                Spacer()
                Text(MemoryUsage.format(memory.total) + " 중")
                    .font(Theme.caption).foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MemoryUsage.format(memory.used))
                    .font(Theme.numeric(28, weight: .semibold))
                Text(String(format: "(%.0f%%)", memory.usedFraction * 100))
                    .font(Theme.numeric(12)).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(pressureColor)
                        .frame(width: max(geo.size.width * memory.usedFraction, 3))
                        .animation(.easeOut(duration: 0.4), value: memory.usedFraction)
                }
            }
            .frame(height: 7)

            HStack(spacing: 12) {
                Text("고정 \(MemoryUsage.format(memory.wired))")
                    .font(Theme.caption).foregroundStyle(.secondary)
                Text("압축 \(MemoryUsage.format(memory.compressed))")
                    .font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: pressureColor)
    }

    /// 지금 온도와 팬을 같이 띄워서, CPU 부하와 발열의 관계가 한눈에 보이게 한다.
    private var thermalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "thermometer.medium").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("발열 / 냉각").font(Theme.label).foregroundStyle(.secondary)
                Spacer()
            }

            if let cpu = model.reading(SensorCatalog.cpuMaxKey) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(model.display(cpu, unit: .celsius, includeSuffix: false))
                        .font(Theme.numeric(28, weight: .semibold))
                        .foregroundStyle(Theme.temperatureColor(cpu))
                    Text(model.format.temperatureUnit.suffix)
                        .font(Theme.numeric(13)).foregroundStyle(.secondary)
                }
            }

            Sparkline(series: model.history(forKey: SensorCatalog.cpuMaxKey),
                      color: Theme.temperatureColor(model.reading(SensorCatalog.cpuMaxKey) ?? 40))
                .frame(height: 24)
                .clipped()

            if let fan = model.fans.first {
                HStack(spacing: 5) {
                    Image(systemName: "fan.fill").font(.system(size: 9))
                        .foregroundStyle(Theme.fanColor(fan.loadFraction))
                    Text("\(Int(fan.currentRPM)) rpm").font(Theme.numeric(11))
                    if let power = model.reading("PSTR") {
                        Text("· \(String(format: "%.1fW", power))")
                            .font(Theme.numeric(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 프로세스 목록

    private var processToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("프로세스 이름이나 PID", text: $ui.search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .frame(width: 230)

            Picker("", selection: $ui.sortKey) {
                ForEach(ActivityState.SortKey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)

            Spacer()

            if let error = model.lastError {
                Text(error).font(Theme.caption).foregroundStyle(.orange).lineLimit(1)
            }

            Text(isSearching || model.processes.count <= Self.visibleLimit
                 ? "\(filtered.count)개"
                 : "\(filtered.count) / \(model.processes.count)개")
                .font(Theme.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.gridSpacing)
        .padding(.vertical, 8)
    }

    private var processList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                ForEach(filtered) { process in
                    row(process)
                    Divider().opacity(0.35)
                }
            }
            .padding(.horizontal, Theme.gridSpacing)
            .padding(.bottom, Theme.gridSpacing)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("프로세스").font(Theme.label).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").font(Theme.label).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text("메모리").font(Theme.label).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text("PID").font(Theme.label).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text("").frame(width: 34)
        }
        .padding(.vertical, 6)
    }

    private func row(_ process: ProcessEntry) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                // CPU 를 많이 쓰는 프로세스일수록 색이 진해진다.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.temperatureColor(40 + process.cpuPercent * 0.6))
                    .frame(width: 3, height: 16)
                Text(process.name).font(.system(size: 12)).lineLimit(1)
                if !process.isOwnedByCurrentUser {
                    Text(process.user).font(Theme.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // CPU 비중을 막대로도 같이 보여준다.
            HStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(Color.accentColor.opacity(0.65))
                            .frame(width: max(geo.size.width * min(process.cpuPercent / 100, 1), 1))
                    }
                }
                .frame(width: 34, height: 5)
                Text(String(format: "%.1f%%", process.cpuPercent))
                    .font(Theme.numeric(11))
                    .frame(width: 50, alignment: .trailing)
            }
            .frame(width: 92, alignment: .trailing)

            Text(MemoryUsage.format(process.memoryBytes))
                .font(Theme.numeric(11)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)

            Text(String(process.pid))
                .font(Theme.numeric(11)).foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)

            Button {
                ui.confirmingKill = process
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(process.isOwnedByCurrentUser ? Color.red.opacity(0.75)
                                                                  : Color.secondary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .frame(width: 34)
            .disabled(!process.isOwnedByCurrentUser)
            .help(process.isOwnedByCurrentUser ? "종료" : "\(process.user) 소유라 종료할 수 없습니다")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
