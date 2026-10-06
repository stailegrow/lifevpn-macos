import AppKit
import SwiftUI

struct AddSheet: View {
    enum Mode: String, Identifiable {
        case subscription
        case links
        var id: String { rawValue }
    }

    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State var mode: Mode
    @State private var url = ""
    @State private var name = ""
    @State private var text = ""
    @State private var isWorking = false
    @State private var problem: String?
    @State private var result: String?

    var body: some View {
        SheetChrome(title: L.t("Добавить", "Add"), width: 470) {
            HUDSegmented(selection: $mode, options: [
                (.subscription, L.t("Подписка", "Subscription")),
                (.links, L.t("Ссылки", "Links"))
            ])

            switch mode {
            case .subscription: subscriptionForm
            case .links:        linksForm
            }

            // Буфер и QR живут в меню на «плюсе» — дублировать их здесь
            // значит предлагать два пути к одному и тому же действию.
            Text(mode == .subscription
                 ? L.t("Ссылка из буфера или с QR-кода добавляется сразу — через меню на «плюсе».", "A link from the clipboard or a QR code is added right away — from the “plus” menu.")
                 : L.t("Одна или несколько ссылок, по одной в строке.", "One or more links, one per line."))
                .font(Typography.body(10.5))
                .foregroundStyle(palette.textSecondary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(Typography.body(11))
                    .foregroundStyle(palette.accent)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.body(11))
                    .foregroundStyle(palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
                Text(L.t("Загружаю…", "Loading…"))
                    .font(Typography.code(10))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button(L.t("Закрыть", "Close")) { dismiss() }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(mode == .subscription ? L.t("Загрузить", "Load") : L.t("Добавить", "Add")) {
                Task { await submit() }
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || isEmpty)
        }
    }

    // MARK: - Формы

    private var subscriptionForm: some View {
        VStack(alignment: .leading, spacing: UI.s(8)) {
            Text(L.t("Узлы подтянутся сразу и дальше будут обновляться сами: добавленные ", "Nodes are pulled in at once and keep updating themselves: the ones added ")
                 + L.t("и удалённые на панели появятся и исчезнут здесь.", "and removed on the panel appear and disappear here."))
                .font(Typography.body(11))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HUDTextField(placeholder: "https://…", text: $url, monospaced: true)
            HUDTextField(placeholder: L.t("Название — можно задать своё", "Name — you can set your own"), text: $name)
        }
    }

    private var linksForm: some View {
        VStack(alignment: .leading, spacing: UI.s(8)) {
            Text(L.t("Такие узлы живут отдельно от подписок и сами не обновляются.", "Such nodes live apart from subscriptions and do not update themselves."))
                .font(Typography.body(11))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HUDTextArea(text: $text, height: UI.s(140))
        }
    }

    private var isEmpty: Bool {
        switch mode {
        case .subscription: return url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .links:        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Отправка

    private func submit() async {
        problem = nil
        result = nil

        switch mode {
        case .subscription:
            isWorking = true
            let subscription = store.addSubscription(url: url, name: name)
            let ok = await store.refresh(subscription)
            isWorking = false

            let stored = store.subscriptions.first { $0.id == subscription.id }
            if ok {
                url = ""
                name = ""
                dismiss()
            } else {
                problem = stored?.lastError ?? L.t("Не удалось загрузить подписку.", "Could not load the subscription.")
                // Битую подписку не оставляем висеть в списке.
                store.removeSubscription(subscription.id)
            }

        case .links:
            let parsed = LinkParser.parseMany(text)
            problem = parsed.errors.first
            let added = store.add(parsed.configs)
            if !parsed.configs.isEmpty, parsed.errors.isEmpty {
                text = ""
                dismiss()
            } else {
                result = added > 0 ? L.t("Добавлено узлов: \(added)", "Nodes added: \(added)") : nil
            }
        }
    }
}

// MARK: - Переименование подписки

struct RenameSubscriptionSheet: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    let subscription: Subscription
    @State private var name: String = ""

    var body: some View {
        SheetChrome(title: L.t("Название подписки", "Subscription name"),
                    subtitle: L.t("Имя видно только тебе. Пустое поле вернёт то, что присылает панель.", "The name is visible only to you. An empty field restores what the panel sends."),
                    width: 400) {
            HUDTextField(placeholder: subscription.displayName, text: $name)
        } footer: {
            Spacer()
            Button(L.t("Отмена", "Cancel")) { dismiss() }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(L.t("Сохранить", "Save")) {
                var updated = subscription
                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                store.updateSubscription(updated)
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { name = subscription.name }
    }
}

// MARK: - Свои домены

struct DirectDomainsSheet: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var original = ""
    @State private var isConfirmingClose = false

    private var hasChanges: Bool { normalized(text) != normalized(original) }

    var body: some View {
        SheetChrome(title: L.t("Свои домены напрямую", "Own domains direct"),
                    subtitle: L.t("Внутренние адреса: почта, вики, файловый сервер. Они пойдут мимо ", "Internal addresses: mail, wiki, file server. They go around the ")
                            + L.t("туннеля и будут резолвиться системным DNS — публичные резолверы ", "tunnel and resolve through the system DNS — public resolvers ")
                            + L.t("о таких именах не знают. По одному в строке.", "do not know such names. One per line."),
                    width: 470) {
            HUDTextArea(text: $text, height: UI.s(150))

            Text(L.t("Например: mail.example.com", "For example: mail.example.com"))
                .font(Typography.code(10))
                .foregroundStyle(palette.textSecondary.opacity(0.7))
        } footer: {
            if hasChanges {
                Text(L.t("Есть несохранённые изменения", "There are unsaved changes"))
                    .font(Typography.code(10))
                    .foregroundStyle(palette.warn)
            }
            Spacer()
            Button(L.t("Закрыть", "Close")) {
                if hasChanges { isConfirmingClose = true } else { dismiss() }
            }
            .buttonStyle(OutlineButtonStyle())
            .keyboardShortcut(.cancelAction)

            Button(L.t("Сохранить", "Save")) { save() }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
        }
        .onAppear {
            text = settings.routing.directDomains.joined(separator: "\n")
            original = text
        }
        .confirmationDialog(L.t("Изменения не сохранены", "Changes are not saved"), isPresented: $isConfirmingClose) {
            Button(L.t("Сохранить и закрыть", "Save and close")) { save() }
            Button(L.t("Закрыть без сохранения", "Close without saving"), role: .destructive) { dismiss() }
            Button(L.t("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("Список доменов изменён. Закрыть без сохранения?", "The domain list has changed. Close without saving?"))
        }
    }

    private func save() {
        settings.routing.directDomains = normalized(text)
        dismiss()
    }

    private func normalized(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
