import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Settings building blocks

enum SettingsStyle {
    static let warning = ChatColors.adaptive(0x9a5b00, 0xf2b45c)
    static let ok = ChatColors.adaptive(0x2e8b57, 0x6fcf97)
    static let rowHeight: CGFloat = 52
    /// Where a divider starts in a card whose rows have a [SettingsIconDisc]: 16 + 30 + 12.
    static let iconInset: CGFloat = 58
}

/// A line icon from `Assets.xcassets/Line` by name (`key`, `spark` …), else the SF Symbol of
/// that name, drawn `size` points square in the current foreground style.
struct LineGlyph: View {
    let name: String
    var size: CGFloat = 18

    private var asset: String? {
        let path = "Line/" + name
        #if os(macOS)
        return NSImage(named: NSImage.Name(path)) == nil ? nil : path
        #else
        return UIImage(named: path) == nil ? nil : path
        #endif
    }

    var body: some View {
        Group {
            if let asset {
                Image(asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: name).font(.system(size: size * 0.86, weight: .regular))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The icon in front of a settings row: a line icon in body colour on a grey rounded tile
/// (30 pt, radius 9). `prominent` draws it on the ink primary colour, as the hub's host card does.
struct SettingsIconDisc: View {
    let symbol: String
    var danger = false
    var prominent = false
    /// On a selected row's tinted background the tile takes the card colour.
    var onCard = false
    var size: CGFloat = 30

    var body: some View {
        let fill = danger ? Color.red.opacity(0.14) : prominent ? ChatColors.primary : onCard ? ChatColors.chip : ChatColors.tile
        LineGlyph(name: symbol, size: (size * 0.6).rounded())
            .foregroundStyle(danger ? Color.red : prominent ? ChatColors.onPrimary : ChatColors.ink)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A 0.5 pt rule between rows, starting under the title (58 with an icon, 16 without).
struct SettingsDivider: View {
    var inset: CGFloat = SettingsStyle.iconInset
    var body: some View {
        Rectangle().fill(ChatColors.line).frame(height: 0.5).padding(.leading, inset).accessibilityHidden(true)
    }
}

/// A settings row: icon, title (and a line under it), the current value, chevron.
struct SettingsRowLabel: View {
    var symbol: String? = nil
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueColor: Color? = nil
    var dot: Color? = nil
    var danger = false
    var chevron = true
    /// False draws a plain line icon, as rows on secondary pages do.
    var tinted = true
    /// The current category in a split view: bold title, icon on the card colour.
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                if tinted { SettingsIconDisc(symbol: symbol, danger: danger, onCard: selected) }
                else {
                    LineGlyph(name: symbol).foregroundStyle(danger ? Color.red : ChatColors.muted).frame(width: 30, height: 30)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(selected ? .semibold : .regular).foregroundStyle(danger ? Color.red : ChatColors.ink)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(ChatColors.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                    Text(value).foregroundStyle(valueColor ?? ChatColors.muted).lineLimit(1)
                }.font(.subheadline)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted.opacity(0.6))
            }
        }.frame(minHeight: SettingsStyle.rowHeight).contentShape(Rectangle())
    }
}

/// A switch row with the same icon and lines as [SettingsRowLabel].
struct SettingsToggleRow: View {
    var symbol: String? = nil
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                if let symbol { SettingsIconDisc(symbol: symbol) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(ChatColors.ink)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(ChatColors.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.frame(minHeight: SettingsStyle.rowHeight)
    }
}

/// The segmented control of a settings row (字号, 语言): a grey well (radius 10) with the chosen
/// segment raised on the card colour (radius 8), 30 pt tall.
struct SettingsSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var expand = false
    var enabled: (Value) -> Bool = { _ in true }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? ChatColors.ink : ChatColors.muted.opacity(enabled(option.0) ? 1 : 0.4))
                        .lineLimit(1).padding(.horizontal, expand ? 4 : 10)
                        .frame(maxWidth: expand ? .infinity : nil, minHeight: 30)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatColors.segmentOn)
                                    .shadow(color: Color(red: 20 / 255, green: 30 / 255, blue: 50 / 255).opacity(0.14), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plain).disabled(!enabled(option.0))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(2).background(ChatColors.segmentWell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A row whose control is a [SettingsSegmented]: inline when it fits, else below the title.
struct SettingsSegmentedRow<Value: Hashable>: View {
    let symbol: String
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Value
    var enabled: (Value) -> Bool = { _ in true }

    private var heading: some View {
        HStack(spacing: 12) {
            SettingsIconDisc(symbol: symbol)
            Text(title).foregroundStyle(ChatColors.ink).lineLimit(1)
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                heading.fixedSize()
                Spacer(minLength: 0)
                SettingsSegmented(options: options, selection: $selection, enabled: enabled).fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                heading
                SettingsSegmented(options: options, selection: $selection, expand: true, enabled: enabled)
            }
        }.padding(.vertical, 4)
    }
}

/// A row in a settings card: the selection tint while pressed.
struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(ChatColors.ink)
            .background(configuration.isPressed ? ChatColors.selected : Color.clear)
    }
}

/// A page section drawn as a card, with an optional title above and note below.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(ChatColors.muted).padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(ChatColors.chip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(ChatColors.muted).padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.bottom, 24)
    }
}

struct SettingsList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.grouped)
        #else
        List { content }.groupedList()
        #endif
    }
}

extension View {
    /// The look every settings page shares.
    func settingsPage(_ title: String) -> some View {
        self.foregroundStyle(ChatColors.ink).scrollContentBackground(.hidden)
            .background(ChatColors.page.ignoresSafeArea()).navigationTitle(title)
    }
}

/// A centred empty state: a glyph, a sentence and a line of detail.
struct HostEmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var action: (String, () -> Void)?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(ChatColors.muted.opacity(0.75))
                .frame(width: 58, height: 58).background(ChatColors.muted.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            Text(title).font(.headline).foregroundStyle(ChatColors.ink).multilineTextAlignment(.center)
            if let message { Text(message).font(.subheadline).foregroundStyle(ChatColors.muted).multilineTextAlignment(.center) }
            if let action { Button(action.0, action: action.1).prominentButton().padding(.top, 6) }
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

struct OfflineMessage: View {
    var symbol = "bolt.horizontal.circle"
    var title = String(localized: "未连接")
    var detail: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(ChatColors.muted)
            Text(title).font(.headline).foregroundStyle(ChatColors.ink).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(ChatColors.muted).multilineTextAlignment(.center)
            }
            if let retry { Button("重试", action: retry).padding(.top, 4) }
        }.frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 12)
    }
}
