import SwiftUI

// MARK: - Каркас окна

/// Общий каркас для всех отдельных окон: заголовок, содержимое, подвал
/// с кнопками. Системные окна выглядят чужеродно рядом с остальным
/// интерфейсом, поэтому своя рамка, свои поля и свои кнопки.
struct SheetChrome<Content: View, Footer: View>: View {
    @Environment(\.palette) private var palette

    let title: String
    var subtitle: String?
    var width: CGFloat = 470
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UI.s(7)) {
                Text(title)
                    .font(Typography.heading(13))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, UI.s(16))
            .padding(.top, UI.s(15))
            .padding(.bottom, UI.s(11))

            Rectangle().fill(palette.cardBorder).frame(height: 1)

            VStack(alignment: .leading, spacing: UI.s(11)) {
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.body(11))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(UI.s(16))

            Rectangle().fill(palette.cardBorder).frame(height: 1)

            HStack(spacing: UI.s(8)) { footer }
                .padding(.horizontal, UI.s(16))
                .padding(.vertical, UI.s(12))
        }
        .frame(width: width)
        .background(palette.background)
    }
}

// MARK: - Переключатель разделов

struct HUDSegmented<Value: Hashable>: View {
    @Environment(\.palette) private var palette

    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: UI.s(6)) {
            ForEach(options, id: \.value) { option in
                let isActive = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(Typography.heading(11))
                        .tracking(0.6)
                        .foregroundStyle(isActive ? palette.accent : palette.textSecondary)
                        .padding(.horizontal, UI.s(14))
                        .padding(.vertical, UI.s(7))
                        .background(
                            CutRect(cut: UI.s(13))
                                .fill(isActive ? palette.accent.opacity(0.22) : palette.rowFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Поля ввода

struct HUDTextField: View {
    @Environment(\.palette) private var palette

    let placeholder: String
    @Binding var text: String
    var monospaced = false

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder)
            .foregroundStyle(palette.textSecondary.opacity(0.6)))
            .textFieldStyle(.plain)
            .font(monospaced ? Typography.code(11.5) : Typography.body(12))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, UI.s(9))
            .padding(.vertical, UI.s(8))
            .background(palette.background.opacity(0.55), in: CutRect(cut: UI.s(12)))
    }
}

struct HUDTextArea: View {
    @Environment(\.palette) private var palette

    @Binding var text: String
    var height: CGFloat = 130

    var body: some View {
        TextEditor(text: $text)
            .font(Typography.code(11))
            .foregroundStyle(palette.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(UI.s(6))
            .frame(height: height)
            .background(palette.background.opacity(0.55), in: CutRect(cut: UI.s(12)))
    }
}


// MARK: - Своё меню

/// Системное всплывающее меню не поддаётся оформлению — рядом с остальным
/// интерфейсом оно выглядит вставкой из другой программы. Поэтому своя
/// панель во всплывающем окне.
struct HUDMenuItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    var subtitle: String?
    var separatorAbove = false
    let action: () -> Void
}

struct HUDMenuPanel: View {
    @Environment(\.palette) private var palette
    let items: [HUDMenuItem]

    @State private var hovered: HUDMenuItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.separatorAbove {
                    Rectangle()
                        .fill(palette.cardBorder)
                        .frame(height: 1)
                        .padding(.vertical, UI.s(4))
                }
                row(item)
            }
        }
        .padding(UI.s(7))
        .frame(width: 250)
        .background(palette.background, in: shape)
        // Обрезка обязательна: без неё прямые углы подсветки строки
        // вылезают за срезанные углы панели.
        .clipShape(shape)
        .shadow(color: .black.opacity(0.20), radius: 16, y: 6)
        // Иначе macOS рисует поверх первой строки синее кольцо фокуса,
        // которое к нашему оформлению отношения не имеет.
        .focusEffectDisabled()
    }

    private var shape: CutRect {
        CutRect(cut: UI.s(13), corners: [.topLeading, .bottomTrailing])
    }

    private func row(_ item: HUDMenuItem) -> some View {
        let isHovered = hovered == item.id
        return Button(action: item.action) {
            HStack(spacing: UI.s(9)) {
                Image(systemName: item.icon)
                    .font(.system(size: UI.s(11), weight: .semibold))
                    .foregroundStyle(isHovered ? palette.accent : palette.textSecondary)
                    .frame(width: UI.s(15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(Typography.body(12))
                        .foregroundStyle(palette.textPrimary)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(Typography.code(9))
                            .foregroundStyle(palette.textSecondary.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UI.s(9))
            .padding(.vertical, UI.s(7))
            .background(
                CutRect(cut: UI.s(6), corners: [.topLeading, .bottomTrailing])
                    .fill(isHovered ? palette.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovered = $0 ? item.id : nil }
    }
}

/// Кнопка выхода: залита тревожным цветом темы. Ей не нужна системная
/// подсветка фокуса — рамку рисуем сами, и синее кольцо в этот язык не
/// вписывается.
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.heading(11))
            .tracking(0.4)
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(palette.bad,
                        in: CutRect(cut: 6, corners: [.topLeading, .bottomTrailing]))
            .overlay(
                CutRect(cut: 6, corners: [.topLeading, .bottomTrailing])
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
