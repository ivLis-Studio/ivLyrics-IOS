import SwiftUI
import UIKit

// MARK: - Tokens

/// Fixed dark tokens. The lyrics popup and the Debug harness keep using these; the settings
/// screens read SettingsPalette from the environment so they follow the manual theme switch.
enum SettingsDesign {
    static let background = Color(hex: "#0B0B0C")
    static let surface = Color(hex: "#141416")
    static let control = Color(hex: "#19191C")
    static let border = Color.white.opacity(0.065)
    static let strongBorder = Color.white.opacity(0.1)
    static let text = Color(hex: "#EDEDEF")
    static let secondary = Color(hex: "#8B8B94")
    static let muted = Color(hex: "#A9A9B1")
    static let accent = Color(hex: "#2563EB")
    static let mint = Color(hex: "#3FB950")
}

/// The settings theme is a manual choice (no automatic option); dark stays the default.
enum SettingsTheme {
    static let dark = "dark"
    static let light = "light"

    static func normalized(_ value: String?) -> String {
        value == light ? light : dark
    }

    static func palette(_ value: String?) -> SettingsPalette {
        normalized(value) == light ? .light : .dark
    }
}

/// Neutral surfaces plus one blue that marks state. Values follow the approved settings lab.
struct SettingsPalette: Sendable {
    let isDark: Bool
    let background: Color
    let surface: Color
    let surface2: Color
    let surface3: Color
    let surface4: Color
    let raise: Color
    let line: Color
    let line2: Color
    let line3: Color
    let text: Color
    let text2: Color
    let text3: Color
    let text4: Color
    let ink: Color
    let inkText: Color
    let accent: Color
    let accentText: Color
    let accentSoft: Color
    let accentLine: Color
    let ok: Color
    let okSoft: Color
    let warn: Color
    let warnSoft: Color
    let danger: Color
    let dangerSoft: Color
    let layerOriginal: Color
    let layerPhonetic: Color
    let layerTranslation: Color

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static let dark = SettingsPalette(
        isDark: true,
        background: Color(hex: "#0B0B0C"),
        surface: Color(hex: "#141416"),
        surface2: Color(hex: "#19191C"),
        surface3: Color(hex: "#212125"),
        surface4: Color(hex: "#2C2C31"),
        raise: Color(hex: "#2A2A2F"),
        line: Color.white.opacity(0.065),
        line2: Color.white.opacity(0.1),
        line3: Color.white.opacity(0.17),
        text: Color(hex: "#EDEDEF"),
        text2: Color(hex: "#A9A9B1"),
        text3: Color(hex: "#8B8B94"),
        text4: Color(hex: "#58585F"),
        ink: Color(hex: "#EDEDEF"),
        inkText: Color(hex: "#0B0B0C"),
        accent: Color(hex: "#2563EB"),
        accentText: Color(hex: "#7AADFF"),
        accentSoft: Color(hex: "#3B82F6").opacity(0.14),
        accentLine: Color(hex: "#3B82F6").opacity(0.55),
        ok: Color(hex: "#3FB950"),
        okSoft: Color(hex: "#3FB950").opacity(0.12),
        warn: Color(hex: "#D6A33A"),
        warnSoft: Color(hex: "#D6A33A").opacity(0.12),
        danger: Color(hex: "#F2554E"),
        dangerSoft: Color(hex: "#F2554E").opacity(0.12),
        layerOriginal: Color(hex: "#D4D4D8"),
        layerPhonetic: Color(hex: "#E9A23B"),
        layerTranslation: Color(hex: "#3FBF8A")
    )

    static let light = SettingsPalette(
        isDark: false,
        background: Color(hex: "#F6F6F7"),
        surface: Color(hex: "#FFFFFF"),
        surface2: Color(hex: "#F6F6F7"),
        surface3: Color(hex: "#EEEEF0"),
        surface4: Color(hex: "#E1E1E5"),
        raise: Color(hex: "#FFFFFF"),
        line: Color.black.opacity(0.07),
        line2: Color.black.opacity(0.11),
        line3: Color.black.opacity(0.18),
        text: Color(hex: "#18181B"),
        text2: Color(hex: "#52525B"),
        text3: Color(hex: "#64646D"),
        text4: Color(hex: "#A1A1AA"),
        ink: Color(hex: "#18181B"),
        inkText: Color(hex: "#FFFFFF"),
        accent: Color(hex: "#2563EB"),
        accentText: Color(hex: "#1D4ED8"),
        accentSoft: Color(hex: "#2563EB").opacity(0.08),
        accentLine: Color(hex: "#2563EB").opacity(0.45),
        ok: Color(hex: "#1A7F37"),
        okSoft: Color(hex: "#1A7F37").opacity(0.09),
        warn: Color(hex: "#9A6700"),
        warnSoft: Color(hex: "#9A6700").opacity(0.1),
        danger: Color(hex: "#CF222E"),
        dangerSoft: Color(hex: "#CF222E").opacity(0.08),
        layerOriginal: Color(hex: "#3F3F46"),
        layerPhonetic: Color(hex: "#C27612"),
        layerTranslation: Color(hex: "#15845A")
    )
}

private struct SettingsPaletteKey: EnvironmentKey {
    static let defaultValue = SettingsPalette.dark
}

extension EnvironmentValues {
    var settingsPalette: SettingsPalette {
        get { self[SettingsPaletteKey.self] }
        set { self[SettingsPaletteKey.self] = newValue }
    }
}

// MARK: - Native controls

struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.settingsPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        // UIKit owns the switch's intrinsic size, disabled state, accessibility value and hit area.
        Toggle(isOn: configuration.$isOn) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .tint(palette.accent)
        .frame(minHeight: 44)
    }
}

/// Text fields of the dark lyrics popup.
struct SettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(SettingsDesign.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsDesign.strongBorder))
    }
}

/// A real native input frame: SwiftUI's plain TextField can expose only its
/// 22pt text line to accessibility even when an outer layout frame is taller.
struct SettingsSearchField: UIViewRepresentable {
    var prompt: String
    @Binding var text: String
    @Binding var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsPalette) private var palette

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.font = preferredFont
        field.adjustsFontForContentSizeCategory = true
        field.adjustsFontSizeToFitWidth = false
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        let textColor = UIColor(palette.text)
        if field.placeholder != prompt || field.textColor != textColor {
            field.textColor = textColor
            field.attributedPlaceholder = NSAttributedString(
                string: prompt,
                attributes: [.foregroundColor: UIColor(palette.text3)]
            )
        }
        field.tintColor = UIColor(palette.accent)
        field.keyboardAppearance = palette.isDark ? .dark : .light
        if field.accessibilityLabel != prompt { field.accessibilityLabel = prompt }
        field.accessibilityIdentifier = "settings.search"
        let font = preferredFont
        if field.font != font { field.font = font }
        field.isEnabled = isEnabled
        if field.text != text { field.text = text }
        // UIKit keyboard/responder changes must not re-enter a SwiftUI render transaction.
        context.coordinator.scheduleFocus(field)
    }

    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        coordinator.cancelFocusRequests()
        field.delegate = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: max(48, preferredFont.lineHeight + 20))
    }

    private var preferredFont: UIFont {
        let category: UIContentSizeCategory
        switch dynamicTypeSize {
        case .xSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .large: category = .large
        case .xLarge: category = .extraLarge
        case .xxLarge: category = .extraExtraLarge
        case .xxxLarge: category = .extraExtraExtraLarge
        case .accessibility1: category = .accessibilityMedium
        case .accessibility2: category = .accessibilityLarge
        case .accessibility3: category = .accessibilityExtraLarge
        case .accessibility4: category = .accessibilityExtraExtraLarge
        case .accessibility5: category = .accessibilityExtraExtraExtraLarge
        @unknown default: category = .large
        }
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SettingsSearchField
        private var focusRequestID = 0
        init(_ parent: SettingsSearchField) { self.parent = parent }
        func cancelFocusRequests() { focusRequestID &+= 1 }
        func scheduleFocus(_ field: UITextField) {
            cancelFocusRequests()
            guard parent.isFocused != field.isFirstResponder else { return }
            let requestID = focusRequestID
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.focusRequestID == requestID,
                      field.window != nil else { return }
                if self.parent.isFocused && !field.isFirstResponder { field.becomeFirstResponder() }
                else if !self.parent.isFocused && field.isFirstResponder { field.resignFirstResponder() }
            }
        }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.isFocused = false
            textField.resignFirstResponder()
            return true
        }
    }
}

/// UISlider keeps the native adjustable accessibility behavior and touch handling.
struct SettingsSlider: UIViewRepresentable {
    @Binding var value: Double
    var bounds: ClosedRange<Double>
    var step: Double
    var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsPalette) private var palette

    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = SettingsNativeSlider()
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            let circle = CGRect(x: 3, y: 2, width: 24, height: 24)
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: circle)
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.black.withAlphaComponent(0.12).setStroke()
            context.cgContext.setLineWidth(0.5)
            context.cgContext.strokeEllipse(in: circle.insetBy(dx: 0.25, dy: 0.25))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumTrackTintColor = UIColor(palette.accent)
        slider.maximumTrackTintColor = UIColor(palette.surface4)
        slider.minimumValue = Float(bounds.lowerBound)
        slider.maximumValue = Float(bounds.upperBound)
        if !slider.isTracking { slider.value = Float(value) }
        slider.accessibilityValue = String(format: "%g", value)
        (slider as? SettingsNativeSlider)?.accessibilityStep = Float(step)
        slider.isEnabled = isEnabled
        slider.alpha = isEnabled ? 1 : 0.4
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 140, height: 44)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SettingsSlider
        init(_ parent: SettingsSlider) { self.parent = parent }
        @objc func began() { parent.onEditingChanged(true) }
        @objc func ended() { parent.onEditingChanged(false) }
        @objc func changed(_ slider: UISlider) {
            let snapped = parent.bounds.lowerBound + ((Double(slider.value) - parent.bounds.lowerBound) / parent.step).rounded() * parent.step
            parent.value = min(parent.bounds.upperBound, max(parent.bounds.lowerBound, snapped))
            slider.value = Float(parent.value)
            // VoiceOver adjusts without a touch gesture; preserve save-on-finish feedback.
            if !slider.isTracking { parent.onEditingChanged(false) }
        }
    }
}

private final class SettingsNativeSlider: UISlider {
    var accessibilityStep: Float = 1

    override func accessibilityIncrement() { adjustAccessibilityValue(by: accessibilityStep) }
    override func accessibilityDecrement() { adjustAccessibilityValue(by: -accessibilityStep) }

    private func adjustAccessibilityValue(by offset: Float) {
        guard isEnabled else { return }
        value = min(maximumValue, max(minimumValue, value + offset))
        sendActions(for: .valueChanged)
    }
}

struct SettingsActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// Equal segments on one line; options that do not fit (long translations, large text) become a
/// vertical list of the same choices instead of being squeezed or truncated.
struct SettingsSegmentedPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.settingsPalette) private var palette
    var title: String
    @Binding var selection: String
    var options: [(value: String, title: String)]
    var icons: [String: String] = [:]
    var swatches: [String: Color] = [:]

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            list
        } else {
            ViewThatFits(in: .horizontal) {
                segments
                list
            }
        }
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = selection == option.value
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        decoration(option.value)
                        Text(option.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(isOn ? palette.text : palette.text3)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.raise)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.line2))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(option.title)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                let isOn = selection == option.value
                Button { selection = option.value } label: {
                    HStack(spacing: 10) {
                        decoration(option.value)
                        Text(option.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SettingsCheckMark(isOn: isOn)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
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

    @ViewBuilder
    private func decoration(_ value: String) -> some View {
        if let icon = icons[value] {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .accessibilityHidden(true)
        }
        if let swatch = swatches[value] {
            Circle()
                .fill(swatch)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(palette.line3))
                .accessibilityHidden(true)
        }
    }
}

/// Round radio indicator of option cards and stacked choices.
struct SettingsCheckMark: View {
    @Environment(\.settingsPalette) private var palette
    var isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? palette.accent : palette.line3, lineWidth: 1)
                .background(Circle().fill(isOn ? palette.accent : Color.clear))
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct SettingsRowSeparatorModifier: ViewModifier {
    @Environment(\.settingsPalette) private var palette

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            palette.line.frame(height: 1).allowsHitTesting(false)
        }
    }
}

extension View {
    /// Rows draw their own top hairline; SettingsGroup hides the first one.
    func settingsRowSeparator() -> some View {
        modifier(SettingsRowSeparatorModifier())
    }

    /// Text inputs: 44pt high, neutral surface, one-pixel border.
    func settingsFieldChrome() -> some View {
        modifier(SettingsFieldChrome())
    }
}

private struct SettingsFieldChrome: ViewModifier {
    @Environment(\.settingsPalette) private var palette

    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2))
    }
}

/// Lyrics provider capability chips: the whole 44pt-high chip is the toggle.
struct SettingsChipToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsPalette) private var palette
    var systemImage: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                configuration.label
                    .font(.footnote.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(configuration.isOn ? Color.white : palette.text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(configuration.isOn ? palette.accent : palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(configuration.isOn ? Color.clear : palette.line2))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// All settings/popup actions share wrapping text, native button semantics and a full-row hit area.
struct SettingsActionLabel: View {
    var title: String
    var systemImage: String? = nil
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
            else if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Intrinsic-width controls move onto separate rows instead of being compressed on small screens.
struct SettingsAdaptiveActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8, content: content)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { content().fixedSize(horizontal: true, vertical: true) }
                VStack(alignment: .leading, spacing: 8, content: content)
            }
        }
    }
}

