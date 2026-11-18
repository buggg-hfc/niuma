import Foundation

struct StatusLabels: Codable, Equatable {
    private var values: [WorkState: String]

    init(_ values: [WorkState: String] = [:]) { self.values = values }
    subscript(_ state: WorkState) -> String? { values[state] }
    var isEmpty: Bool { values.isEmpty }

    static func cleaned(_ text: String, field: String, limit: Int = 80) throws -> String {
        guard !text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }) else { throw SettingsError(message: "\(field)请输入单行文字") }
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count <= limit else { throw SettingsError(message: "\(field)最多 \(limit) 个字符") }
        return value
    }

    init(from decoder: Decoder) throws {
        values = [:]
        guard let container = try? decoder.container(keyedBy: WorkState.self) else { return }
        for state in container.allKeys {
            if let text = try? container.decode(String.self, forKey: state),
               let value = try? Self.cleaned(text, field: state.defaultLabel), !value.isEmpty {
                values[state] = value
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WorkState.self)
        for (state, value) in values { try container.encode(value, forKey: state) }
    }
}

struct OccupationPreset: Codable, Equatable {
    let id: String
    let name: String
    let labels: StatusLabels

    static let builtIn = [
        OccupationPreset(id: "general", name: "通用", labels: StatusLabels()),
        OccupationPreset(id: "onClock", name: "上钟 / 下钟", labels: StatusLabels([
            .beforeWork: "待上钟", .working: "上钟中", .lunch: "休息中", .afterWork: "已下钟"
        ])),
        OccupationPreset(id: "cook", name: "厨师", labels: StatusLabels([
            .beforeWork: "待开灶", .working: "掌勺中", .lunch: "歇一会儿", .afterWork: "已收灶"
        ])),
        OccupationPreset(id: "construction", name: "建筑工人", labels: StatusLabels([
            .beforeWork: "待开工", .working: "施工中", .lunch: "工间休息", .overtime: "赶工中", .afterWork: "已收工"
        ])),
        OccupationPreset(id: "developer", name: "程序员", labels: StatusLabels([
            .beforeWork: "待开工", .working: "开发中", .lunch: "休息中", .afterWork: "已下线"
        ]))
    ]
}

struct StatusPreferences: Codable, Equatable {
    private(set) var selectedOccupationID = OccupationPreset.builtIn[0].id
    private(set) var customOccupations: [OccupationPreset] = []
    private var overrides: [String: StatusLabels] = [:]

    var occupations: [OccupationPreset] { OccupationPreset.builtIn + customOccupations }
    var canDeleteSelection: Bool { customOccupations.contains { $0.id == selectedOccupationID } }
    var activeOverrides: StatusLabels { overrides[selectedOccupationID] ?? StatusLabels() }

    init() {}

    func defaultLabel(for state: WorkState) -> String {
        let occupation = OccupationPreset.builtIn.first { $0.id == selectedOccupationID }
            ?? customOccupations.first { $0.id == selectedOccupationID }
        return occupation?.labels[state] ?? state.defaultLabel
    }

    func label(for state: WorkState) -> String {
        activeOverrides[state] ?? defaultLabel(for: state)
    }

    mutating func selectOccupation(_ id: String) {
        if occupations.contains(where: { $0.id == id }) { selectedOccupationID = id }
    }

    mutating func setOverrides(_ entries: [WorkState: String]) throws {
        var values: [WorkState: String] = [:]
        for state in WorkState.allCases {
            let value = try StatusLabels.cleaned(entries[state] ?? "", field: "「\(state.defaultLabel)」文案")
            if !value.isEmpty { values[state] = value }
        }
        overrides[selectedOccupationID] = values.isEmpty ? nil : StatusLabels(values)
    }

    mutating func addOccupation(named text: String) throws {
        let name = try availableName(text)
        let labels = WorkState.allCases.reduce(into: [WorkState: String]()) { $0[$1] = label(for: $1) }
        let preset = OccupationPreset(id: UUID().uuidString, name: name, labels: StatusLabels(labels))
        customOccupations.append(preset)
        selectedOccupationID = preset.id
    }

    mutating func deleteSelectedOccupation() {
        guard canDeleteSelection else { return }
        customOccupations.removeAll { $0.id == selectedOccupationID }
        overrides[selectedOccupationID] = nil
        selectedOccupationID = OccupationPreset.builtIn[0].id
    }

    private func availableName(_ text: String) throws -> String {
        let name = try StatusLabels.cleaned(text, field: "职业名称", limit: 32)
        guard !name.isEmpty else { throw SettingsError(message: "请输入职业名称") }
        guard !occupations.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw SettingsError(message: "已有同名职业，请换一个名称")
        }
        return name
    }

    private enum CodingKeys: String, CodingKey { case selectedOccupationID, customOccupations, overrides }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        var ids = Set(OccupationPreset.builtIn.map(\.id))
        if var presets = try? container.nestedUnkeyedContainer(forKey: .customOccupations) {
            while !presets.isAtEnd {
                let source = try presets.superDecoder()
                guard let preset = try? OccupationPreset(from: source), !preset.id.isEmpty,
                      let name = try? availableName(preset.name), ids.insert(preset.id).inserted else { continue }
                customOccupations.append(OccupationPreset(id: preset.id, name: name, labels: preset.labels))
            }
        }
        if let id = try? container.decode(String.self, forKey: .selectedOccupationID), ids.contains(id) {
            selectedOccupationID = id
        }
        if let values = try? container.decode([String: StatusLabels].self, forKey: .overrides) {
            overrides = values.filter { ids.contains($0.key) && !$0.value.isEmpty }
        }
    }
}
