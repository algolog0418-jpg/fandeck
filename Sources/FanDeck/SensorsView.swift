//  SensorsView.swift — 센서 전체 목록
//
//  이 맥은 센서가 174개나 된다. 그냥 나열하면 아무것도 못 찾으므로
//  그룹으로 접고, 검색으로 거르고, 자주 보는 건 즐겨찾기로 위에 고정한다.

import SwiftUI

private final class SensorsState: ObservableObject {
    @Published var collapsedGroups: Set<SensorGroup> = []
    @Published var showOnlyFavorites = false
}

struct SensorsView: View {
    @Bindable var model: AppModel
    @StateObject private var ui = SensorsState()

    private var filtered: [SensorDescriptor] {
        let query = model.sensorSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return model.descriptors.filter { d in
            if ui.showOnlyFavorites && !model.isFavorite(d.key) { return false }
            guard !query.isEmpty else { return true }
            return d.name.lowercased().contains(query)
                || d.englishName.lowercased().contains(query)
                || d.key.lowercased().contains(query)
                || d.group.localizedName.lowercased().contains(query)
        }
    }

    private var grouped: [(SensorGroup, [SensorDescriptor])] {
        let dict = Dictionary(grouping: filtered) { $0.group }
        return SensorGroup.allCases.compactMap { group in
            guard let items = dict[group], !items.isEmpty else { return nil }
            return (group, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.gridSpacing, pinnedViews: []) {
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: model.sensorSearch)
                            .padding(.top, 60)
                    }
                    ForEach(grouped, id: \.0) { group, items in
                        groupSection(group: group, items: items)
                    }
                }
                .padding(Theme.gridSpacing)
            }
        }
        // 센서 탭에 있는 동안에만 전체 센서를 읽는다.
        .onAppear { model.needsAllSensors = true }
        .onDisappear { model.needsAllSensors = false }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("센서 이름이나 SMC 키로 검색", text: $model.sensorSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.sensorSearch.isEmpty {
                    Button { model.sensorSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Toggle(isOn: $ui.showOnlyFavorites) {
                Label("즐겨찾기만", systemImage: "star.fill")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)

            Spacer()

            Text("\(filtered.count) / \(model.descriptors.count)개")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.gridSpacing)
        .padding(.vertical, 9)
    }

    private func groupSection(group: SensorGroup, items: [SensorDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    if ui.collapsedGroups.contains(group) { ui.collapsedGroups.remove(group) }
                    else { ui.collapsedGroups.insert(group) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(ui.collapsedGroups.contains(group) ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Image(systemName: group.symbolName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(group.localizedName)
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(items.count)")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Spacer()
                    if let summary = groupSummary(items) {
                        Text(summary).font(Theme.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if !ui.collapsedGroups.contains(group) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(items.sorted { $0.name < $1.name }) { d in
                        SensorCell(descriptor: d,
                                   value: model.reading(d.key),
                                   isFavorite: model.isFavorite(d.key),
                                   format: model.format,
                                   onToggleFavorite: { model.toggleFavorite(d.key) })
                    }
                }
            }
        }
    }

    /// 그룹을 접었을 때도 최고값은 보이게 해 둔다.
    private func groupSummary(_ items: [SensorDescriptor]) -> String? {
        let values = items.compactMap { model.reading($0.key) }
        guard let maximum = values.max(), let unit = items.first?.unit else { return nil }
        return "최고 " + model.display(maximum, unit: unit)
    }
}
