import SwiftUI
import UIKit

// MARK: - Sections and groups

struct SettingsSectionHeader: View {
    @Environment(\.settingsPalette) private var palette
    var title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .foregroundStyle(palette.text)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.trimmed.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}

/// A grouped card. Rows separate themselves with a top hairline; the first one is clipped away.
struct SettingsGroup<Content: View>: View {
    @Environment(\.settingsPalette) private var palette
    private let tone: Tone
    private let content: Content

    enum Tone { case normal, muted }

    init(tone: Tone = .normal, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone == .muted ? palette.surface2 : palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line))
    }
}

/// Title and description of a row. Both wrap; nothing is truncated at large text sizes.
struct SettingsTextBlock: View {
    @Environment(\.settingsPalette) private var palette
    var title: String
    var description: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.text)
            }
            if !description.trimmed.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// On/off row. As on iOS, only the switch toggles; the label stays readable text.
struct SettingsToggleRow: View {
    var title: String
    var description: String = ""
    @Binding var isOn: Bool
    var identifier: String
    var indent = false

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsTextBlock(title: title, description: description)
        }
        .toggleStyle(SettingsSwitchStyle())
        .padding(.leading, indent ? 38 : 16)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(alignment: .topLeading) {
            if indent { SettingsIndentGuide() }
        }
        .settingsRowSeparator()
        .accessibilityIdentifier(identifier)
        .debugSettingsHitArea(identifier)
    }
}

private struct SettingsIndentGuide: View {
    @Environment(\.settingsPalette) private var palette

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 21, y: 0))
            path.addLine(to: CGPoint(x: 21, y: 22))
            path.addQuadCurve(to: CGPoint(x: 29, y: 30), control: CGPoint(x: 21, y: 30))
        }
        .stroke(palette.line3, lineWidth: 1)
        .frame(width: 32, height: 32)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Label and description above a full-width control.
struct SettingsStackRow<Control: View>: View {
    @Environment(\.settingsPalette) private var palette
    private let title: String
    private let description: String
    private let value: String
    private let control: Control

    init(title: String, description: String = "", value: String = "", @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.value = value
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty || !description.trimmed.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SettingsTextBlock(title: title, description: description)
                    if !value.isEmpty {
                        Text(value)
                            .font(.footnote.weight(.medium).monospacedDigit())
                            .foregroundStyle(palette.text3)
                            .fixedSize()
                    }
                }
            }
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowSeparator()
    }
}

/// Short hint or status line inside a group.
struct SettingsNoteRow: View {
    @Environment(\.settingsPalette) private var palette
    var text: String
    var systemImage: String? = "info.circle"
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(color ?? palette.text3)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(color ?? palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .settingsRowSeparator()
    }
}

/// A dot (or spinner) and a status sentence.
struct SettingsStatusLine: View {
    @Environment(\.settingsPalette) private var palette
    var text: String
    var dot: Color? = nil
    var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(dot ?? palette.text4).frame(width: 7, height: 7)
                }
            }
            .frame(width: 16)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(palette.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Subhead" inside a group, for example Cloud settings sync inside Account.
struct SettingsSubhead: View {
    @Environment(\.settingsPalette) private var palette
    var title: String
    var description: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.text2)
                .accessibilityAddTraits(.isHeader)
            if !description.trimmed.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(palette.text3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .settingsRowSeparator()
    }
}

// MARK: - Buttons

/// Full-width action row (iOS list idiom): accent text, red when destructive, chevron at the end.
struct SettingsActionRow: View {
    enum Role { case normal, danger }

    @Environment(\.settingsPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var title: String
    var subtitle: String = ""
    var role: Role = .normal
    var systemImage: String = "chevron.right"
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(role == .danger ? palette.danger : palette.accentText)
                    if !subtitle.trimmed.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(palette.text3)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if busy {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.text4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .settingsRowSeparator()
    }
}

struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.settingsPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? palette.surface3 : Color.clear)
    }
}

/// Bordered 44pt button for inline actions (copy, project page, model download …).
struct SettingsButtonStyle: ButtonStyle {
    enum Tone { case normal, primary, danger }

    @Environment(\.settingsPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var tone: Tone = .normal
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch tone {
        case .normal: return palette.text
        case .primary: return palette.inkText
        case .danger: return palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch tone {
        case .normal: return pressed ? palette.surface4 : palette.surface2
        case .primary: return pressed ? palette.ink.opacity(0.82) : palette.ink
        case .danger: return pressed ? palette.dangerSoft : Color.clear
        }
    }

    private var border: Color {
        switch tone {
        case .normal: return palette.line2
        case .primary: return Color.clear
        case .danger: return palette.danger.opacity(0.35)
        }
    }
}

/// Label used inside SettingsButtonStyle buttons.
struct SettingsButtonLabel: View {
    var title: String
    var systemImage: String? = nil
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Square icon button with a 44pt hit area (reorder arrows, refresh …).
struct SettingsIconButton: View {
    @Environment(\.settingsPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(palette.text2)
                .frame(width: 38, height: 36)
                .background(palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line2))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}

/// Small status label.
struct SettingsPill: View {
    enum Tone { case neutral, ok, accent, warn, danger }

    @Environment(\.settingsPalette) private var palette
    var text: String
    var tone: Tone = .neutral
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return palette.text2
        case .ok: return palette.ok
        case .accent: return palette.accentText
        case .warn: return palette.warn
        case .danger: return palette.danger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return palette.surface3
        case .ok: return palette.okSoft
        case .accent: return palette.accentSoft
        case .warn: return palette.warnSoft
        case .danger: return palette.dangerSoft
        }
    }
}

// MARK: - Values

/// Slider plus an editable number (the value is also typed in, as in the lab).
struct SettingsValueSlider: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 92
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var decimals: Int = 0
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            SettingsSlider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                .accessibilityLabel(label)
                .accessibilityValue(SettingsNumberField.format(value, decimals: decimals) + unit)
            SettingsNumberField(label: label, value: $value, range: range, step: step, unit: unit, decimals: decimals) {
                onEditingChanged(false)
            }
            .frame(width: fieldWidth)
        }
    }
}

/// Numeric entry that snaps to the slider's step and range when editing ends.
struct SettingsNumberField: View {
    @Environment(\.settingsPalette) private var palette
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var unit: String
    var decimals: Int
    var onCommit: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(palette.text)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(label)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(palette.text3)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? palette.accentLine : palette.line2))
        .onAppear { text = Self.format(value, decimals: decimals) }
        .onChange(of: value) { _, newValue in
            if !focused { text = Self.format(newValue, decimals: decimals) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    static func format(_ value: Double, decimals: Int) -> String {
        decimals > 0 ? String(format: "%.\(decimals)f", value) : String(Int(value.rounded()))
    }

    private func commit() {
        let typed = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(typed), parsed.isFinite else {
            text = Self.format(value, decimals: decimals)
            return
        }
        let snapped = range.lowerBound + ((parsed - range.lowerBound) / step).rounded() * step
        let clamped = min(range.upperBound, max(range.lowerBound, snapped))
        if abs(clamped - value) > step / 1000 {
            value = clamped
            onCommit()
        }
        text = Self.format(value, decimals: decimals)
    }
}

/// − value + control (max tokens).
struct SettingsStepperField: View {
    @Environment(\.settingsPalette) private var palette
    var label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var decrementLabel: String
    var incrementLabel: String

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconButton(systemImage: "minus", label: decrementLabel) {
                value = max(range.lowerBound, value - step)
            }
            .disabled(value <= range.lowerBound)
            SettingsNumberField(
                label: label,
                value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step),
                unit: "",
                decimals: 0,
                onCommit: {}
            )
            SettingsIconButton(systemImage: "plus", label: incrementLabel) {
                value = min(range.upperBound, value + step)
            }
            .disabled(value >= range.upperBound)
        }
    }
}

// MARK: - Choices

struct SettingsChoice: Identifiable, Hashable {
    let value: String
    let title: String
    var subtitle: String = ""
    var id: String { value }
}

/// Radio cards (two columns, one column at accessibility sizes).
struct SettingsOptionCards<Visual: View>: View {
    @Environment(\.settingsPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var title: String
    var options: [SettingsChoice]
    @Binding var selection: String
    var columns: Int = 2
    var visual: (SettingsChoice) -> Visual

    init(title: String, options: [SettingsChoice], selection: Binding<String>, columns: Int = 2,
         @ViewBuilder visual: @escaping (SettingsChoice) -> Visual) {
        self.title = title
        self.options = options
        _selection = selection
        self.columns = columns
        self.visual = visual
    }

    var body: some View {
        let count = usesSingleColumn ? 1 : max(1, columns)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count), spacing: 8) {
            ForEach(options) { option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        visual(option)
                        HStack(alignment: .top, spacing: 8) {
                            Text(option.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(palette.text)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SettingsCheckMark(isOn: isOn)
                        }
                        if !option.subtitle.isEmpty {
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(palette.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isOn ? palette.accent : palette.line2, lineWidth: isOn ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(option.title)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    /// Text-only cards fall back to one column when a label would otherwise break inside a word
    /// (long Latin-script words such as "(Romanization)") or when the text size is above the default.
    private var usesSingleColumn: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }
        guard Visual.self == EmptyView.self else { return false }
        if dynamicTypeSize > .large { return true }
        return options.contains { option in
            option.title.count > 30 || option.title.split(whereSeparator: \.isWhitespace).contains { word in
                word.count > 11 && word.unicodeScalars.allSatisfy { $0.value < 0x0E00 }
            }
        }
    }
}

extension SettingsOptionCards where Visual == EmptyView {
    init(title: String, options: [SettingsChoice], selection: Binding<String>, columns: Int = 2) {
        self.init(title: title, options: options, selection: selection, columns: columns) { _ in EmptyView() }
    }
}

/// Button that shows the current choice and opens a sheet with the full list.
struct SettingsPickerButton: View {
    @Environment(\.settingsPalette) private var palette
    var title: String
    var value: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.text3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Bottom sheet with every option, a search box for long lists, and a check on the current one.
struct SettingsOptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsPalette) private var palette
    var title: String
    var options: [SettingsChoice]
    var selection: String
    var searchPrompt: String
    var closeLabel: String
    var emptyText: String
    var onSelect: (String) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .foregroundStyle(palette.text2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(closeLabel)
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.top, 16)
            if options.count > 7 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.text3)
                        .accessibilityHidden(true)
                    TextField(searchPrompt, text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(palette.text)
                }
                .settingsFieldChrome()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        Text(emptyText)
                            .font(.footnote)
                            .foregroundStyle(palette.text3)
                            .padding(16)
                    }
                    ForEach(filtered) { option in
                        let isOn = option.value == selection
                        Button {
                            onSelect(option.value)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.body)
                                        .foregroundStyle(palette.text)
                                    if !option.subtitle.isEmpty {
                                        Text(option.subtitle)
                                            .font(.footnote)
                                            .foregroundStyle(palette.text3)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if isOn {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(palette.accentText)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(isOn ? palette.surface3 : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(palette.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(palette.colorScheme)
    }

    private var filtered: [SettingsChoice] {
        let needle = SettingsSearchText.normalized(query)
        guard !needle.isEmpty else { return options }
        return options.filter {
            SettingsSearchText.normalized($0.title + " " + $0.subtitle + " " + $0.value).contains(needle)
        }
    }
}

// MARK: - Search text

enum SettingsSearchText {
    private static let initials: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

    /// Lowercased, without spaces, diacritics or width differences.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
    }

    /// Hangul syllables reduced to their initial consonants ("밝기" → "ㅂㄱ").
    static func initialConsonants(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            let value = Int(scalar.value)
            guard (0xAC00...0xD7A3).contains(value) else { return Character(scalar) }
            return initials[(value - 0xAC00) / 588]
        })
    }

    static func isInitialConsonantQuery(_ query: String) -> Bool {
        !query.isEmpty && query.unicodeScalars.allSatisfy { (0x3131...0x314E).contains(Int($0.value)) }
    }
}

// MARK: - Layout

/// Wraps chips onto as many lines as needed.
struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width.map { $0.isFinite ? $0 : CGFloat.greatestFiniteMagnitude } ?? CGFloat.greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = measured(subview, maxWidth: maxWidth)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = measured(subview, maxWidth: maxWidth)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func measured(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

// MARK: - Scroll position

/// Remembers each settings page's scroll offset while the settings stay open.
final class SettingsScrollMemory {
    var offsets: [String: CGFloat] = [:]
}

/// Placed in a ScrollView's content: finds the backing UIScrollView, restores the remembered
/// offset once and keeps recording it. Without a UIScrollView it does nothing.
struct SettingsScrollKeeper: UIViewRepresentable {
    var key: String
    var memory: SettingsScrollMemory
    var restores: Bool

    func makeUIView(context: Context) -> KeeperView {
        let view = KeeperView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: KeeperView, context: Context) {
        view.key = key
        view.memory = memory
        view.restores = restores
    }

    static func dismantleUIView(_ view: KeeperView, coordinator: ()) {
        view.stop()
    }

    final class KeeperView: UIView {
        var key = ""
        weak var memory: SettingsScrollMemory?
        var restores = true
        private var observation: NSKeyValueObservation?
        private var attached = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !attached else { return }
            var candidate = superview
            while let view = candidate, !(view is UIScrollView) { candidate = view.superview }
            guard let scrollView = candidate as? UIScrollView else { return }
            attached = true
            let saved = restores ? (memory?.offsets[key] ?? 0) : 0
            if saved > 1 { restore(saved, in: scrollView, attempt: 0) }
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                DispatchQueue.main.async {
                    guard let self, let memory = self.memory else { return }
                    memory.offsets[self.key] = max(0, offset)
                }
            }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
        }

        private func restore(_ offset: CGFloat, in scrollView: UIScrollView, attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.06)) { [weak scrollView] in
                guard let scrollView else { return }
                let inset = scrollView.adjustedContentInset
                let maximum = scrollView.contentSize.height + inset.bottom - scrollView.bounds.height
                if maximum + inset.top < offset - 1 && attempt < 6 {
                    self.restore(offset, in: scrollView, attempt: attempt + 1)
                    return
                }
                let target = min(max(-inset.top, offset - inset.top), max(-inset.top, maximum))
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
            }
        }
    }
}

// MARK: - Tiles

/// On/off tile with an icon and a state word (AI translation / pronunciation).
struct SettingsToggleTile: View {
    @Environment(\.settingsPalette) private var palette
    var title: String
    var systemImage: String
    var color: Color
    var onText: String
    var offText: String
    @Binding var isOn: Bool
    var identifier: String

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.footnote.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(isOn ? palette.background : palette.text3)
                        .frame(width: 28, height: 28)
                        .background(isOn ? color : palette.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Spacer(minLength: 4)
                    Text(isOn ? onText : offText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isOn ? palette.text : palette.text3)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isOn ? color.opacity(0.6) : palette.line2, lineWidth: isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn).toggleStyle(.switch)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Secure text field with a show/hide button.
struct SettingsSecureField: View {
    @Environment(\.settingsPalette) private var palette
    var title: String
    @Binding var text: String
    var showLabel: String
    var hideLabel: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body)
            .foregroundStyle(palette.text)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.footnote.weight(.medium))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .foregroundStyle(palette.text3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? hideLabel : showLabel)
        }
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
    }
}

/// Lyric layer chips (hidden / original / pronunciation / translation): a coloured square marks the layer.
struct SettingsLayerChipStyle: ToggleStyle {
    @Environment(\.settingsPalette) private var palette
    var color: Color?

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                if let color {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .opacity(configuration.isOn ? 1 : 0.4)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
                configuration.label
                    .font(.footnote.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(configuration.isOn ? palette.text : palette.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(configuration.isOn ? palette.surface : palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(configuration.isOn ? palette.line3 : palette.line2))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

// MARK: - Search reveal

/// Gives its content the natural height for the offered width, never more and never above `maxHeight`
/// (content taller than the cap is clipped by the caller). Flexible frames would instead stretch to the offer.
struct SettingsNaturalHeightLayout: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let natural = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        content.place(at: bounds.origin, anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: natural.height))
    }
}

private struct SettingsRevealHighlight: ViewModifier {
    @Environment(\.settingsPalette) private var palette
    var isFlashing: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isFlashing {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.accentLine, lineWidth: 1.5))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Scroll target of search results; flashes briefly after a jump.
    func settingsRow(_ id: String, flashing: String?) -> some View {
        modifier(SettingsRevealHighlight(isFlashing: flashing == id)).id(id)
    }
}

