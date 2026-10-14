import SwiftUI
import UIKit

/// Settings-only tokens shared by the native controls and grouped rows.
enum SettingsDesign {
    static let background = Color(hex: "#0D0D11")
    static let surface = Color(hex: "#151519")
    static let control = Color(hex: "#1B1B21")
    static let border = Color.white.opacity(0.07)
    static let strongBorder = Color.white.opacity(0.14)
    static let text = Color(hex: "#F1F0F4")
    static let secondary = Color(hex: "#8F8E98")
    static let muted = Color(hex: "#A3A2AD")
    static let accent = Color(hex: "#FF6B4A")
    static let mint = Color(hex: "#5FCE9B")
}

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // UIKit owns the switch's intrinsic size, disabled state, accessibility value and hit area.
        Toggle(isOn: configuration.$isOn) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .tint(SettingsDesign.accent)
        .frame(minHeight: 44)
    }
}

struct SettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(SettingsDesign.control, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SettingsDesign.strongBorder))
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

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.textColor = UIColor(SettingsDesign.text)
        field.tintColor = UIColor(SettingsDesign.accent)
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
        if field.placeholder != prompt { field.placeholder = prompt }
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

    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = SettingsNativeSlider()
        slider.minimumTrackTintColor = UIColor(SettingsDesign.accent)
        slider.maximumTrackTintColor = UIColor(SettingsDesign.control)
        slider.thumbTintColor = UIColor(SettingsDesign.accent)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { context in
            UIColor(SettingsDesign.accent.opacity(0.18)).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 26, height: 26))
            UIColor(SettingsDesign.accent).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 18, height: 18))
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
        slider.minimumValue = Float(bounds.lowerBound)
        slider.maximumValue = Float(bounds.upperBound)
        slider.value = Float(value)
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

struct SettingsSegmentedPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var title: String
    @Binding var selection: String
    var options: [(value: String, title: String)]

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            menu
        } else {
            ViewThatFits(in: .horizontal) {
                segments
                menu
            }
        }
    }

    private var menu: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .tint(SettingsDesign.text)
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .background(SettingsDesign.control, in: RoundedRectangle(cornerRadius: 11))
    }

    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.pretendard(13.5, weight: .semibold))
                        .foregroundStyle(selection == option.value ? SettingsDesign.background : SettingsDesign.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(selection == option.value ? SettingsDesign.text : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(option.title)")
                .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(SettingsDesign.control, in: RoundedRectangle(cornerRadius: 11))
    }
}

extension View {
    func settingsRowSeparator() -> some View {
        overlay(alignment: .bottom) { SettingsDesign.border.frame(height: 1) }
    }
}

struct SettingsChipToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.pretendard(13, weight: .semibold))
                .foregroundStyle(configuration.isOn ? SettingsDesign.mint : SettingsDesign.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(configuration.isOn ? SettingsDesign.mint.opacity(0.16) : SettingsDesign.control, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
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
