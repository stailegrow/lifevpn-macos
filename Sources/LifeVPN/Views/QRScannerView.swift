// AVFoundation писался до строгой конкурентности: AVCaptureSession и его
// соседи не помечены Sendable, хотя работать с ними с одной очереди
// безопасно. @preconcurrency снимает эти жалобы, не отключая проверки
// для нашего собственного кода.
@preconcurrency import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Модель сканера: держит сессию камеры и состояние доступа.
///
/// Намеренно без async/await и без @MainActor. Прошлые две версии падали
/// в динамической проверке актора посреди обсчёта раскладки: @StateObject
/// строит объект из неизолированного замыкания, и каждое обращение к
/// свойствам изолированного класса из тела представления превращалось в
/// такую проверку. На колбэках и явных переходах в главную очередь
/// проверять нечего, поэтому и падать негде.
/// @unchecked Sendable — обещание, которое класс выполняет сам: все
/// изменения состояния идут через главную очередь, работа с сессией — через
/// одну служебную. Компилятор этого не докажет, но нарушить это здесь негде.
final class CameraScanner: ObservableObject, @unchecked Sendable {

    enum Phase: Equatable {
        case idle
        case running
        case denied
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var code: String?

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sink = FrameSink()
    private let queue = DispatchQueue(label: "com.stailegrow.lifevpn.camera")
    private var isConfigured = false

    func start() {
        guard phase != .running else { return }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.phase = .denied
                    return
                }
                self.beginSession()
            }
        }
    }

    func stop() {
        let sink = self.sink
        let session = self.session
        queue.async {
            sink.onCode = nil
            session.stopRunning()
        }
        phase = .idle
    }

    // MARK: - Сессия

    private func beginSession() {
        do {
            try configureIfNeeded()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // startRunning блокирует вызывающий поток — уводим с главного.
        // Обработчик ставим на той же очереди, что и разбор кадров, чтобы
        // не читать его с двух потоков сразу.
        let sink = self.sink
        let session = self.session
        // Оба захвата слабые и указаны явно: внешнее замыкание иначе держит
        // сканер сильной ссылкой, а внутреннее живёт в sink, который держит
        // сам сканер, — получилось бы кольцо.
        queue.async { [weak self] in
            sink.onCode = { [weak self] value in
                // Слабая ссылка — это изменяемая переменная, и отдавать её в
                // другое замыкание новый компилятор не разрешает. Неизменяемая
                // копия ведёт себя так же, но проверку проходит.
                let scanner = self
                DispatchQueue.main.async { scanner?.code = value }
            }
            session.startRunning()
        }
        phase = .running
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw Failure(message: L.t("Камера не найдена.", "No camera found."))
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .high

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw Failure(message: L.t("Камера занята другим приложением.", "The camera is busy in another app."))
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure(message: L.t("Не удалось получить кадры с камеры.", "Could not get frames from the camera."))
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(sink, queue: queue)
        session.addOutput(output)

        session.commitConfiguration()
        isConfigured = true
    }

    /// Разбор кадров.
    ///
    /// Штатный AVCaptureMetadataOutput на маке распознавание кодов не
    /// отдаёт — список поддерживаемых типов так и остаётся пустым. Поэтому
    /// читаем сами: берём кадр и отдаём его тому же CIDetector, что уже
    /// разбирает картинки из файла и буфера. Он же и работает всегда.
    private final class FrameSink: NSObject,
                                   AVCaptureVideoDataOutputSampleBufferDelegate,
                                   @unchecked Sendable {
        /// Ставится и читается только с очереди камеры.
        var onCode: ((String) -> Void)?

        private var hasReported = false
        private var frame = 0
        private let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                          context: CIContext(options: nil),
                                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !hasReported, let detector, onCode != nil else { return }

            // Камера отдаёт три десятка кадров в секунду — разбирать каждый
            // незачем, хватает нескольких: код никуда не убегает.
            frame += 1
            guard frame % 4 == 0 else { return }

            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: pixels)

            let value = detector.features(in: image)
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                .first { !$0.isEmpty }
            guard let value else { return }

            hasReported = true
            onCode?(value)
        }
    }
}

// MARK: - Окно сканирования

struct QRScannerSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Вызывается с содержимым первого распознанного кода.
    let onFound: (String) -> Void

    @StateObject private var scanner = CameraScanner()

    /// Сколько секунд ещё ищем код. Камера не должна работать бесконечно,
    /// если окно просто забыли закрыть, но и обрывать поиск на полуслове
    /// нельзя — двадцати секунд хватает, чтобы поднести код спокойно.
    @State private var secondsLeft = Self.searchWindow
    private static let searchWindow = 20

    var body: some View {
        SheetChrome(title: L.t("Сканировать QR", "Scan QR"),
                    subtitle: L.t("Поднеси код к камере — распознается сам.", "Hold the code up to the camera — it is picked up on its own."),
                    width: 460) {
            preview

            if scanner.phase == .denied {
                Button(L.t("Открыть настройки доступа", "Open privacy settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(OutlineButtonStyle())
                .focusEffectDisabled()
            }
        } footer: {
            countdown
            Spacer()
            Button(L.t("Закрыть", "Close")) { dismiss() }
                .buttonStyle(DangerButtonStyle())
                .focusEffectDisabled()
                .keyboardShortcut(.cancelAction)
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .task {
            // Отсчёт идёт только пока камера действительно смотрит: пока
            // ждём разрешения или показываем ошибку, окно никуда не денется.
            // Задача живёт ровно столько, сколько открыто окно, — закрыл
            // сам, и отсчёт отменяется вместе с ней.
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if scanner.phase == .running { secondsLeft -= 1 }
            }
            dismiss()
        }
        .onChange(of: scanner.code) { _, new in
            guard let new else { return }
            onFound(new)
            dismiss()
        }
    }

    /// Видимый остаток времени — окно не должно закрываться внезапно.
    @ViewBuilder
    private var countdown: some View {
        if scanner.phase == .running {
            HStack(spacing: 6) {
                Text(verbatim: L.t("ПОИСК", "SEARCH"))
                    .font(Typography.code(8.5))
                    .tracking(1)
                Text(verbatim: "\(secondsLeft) c")
                    .font(Typography.code(9.5))
                    .monospacedDigit()
            }
            .foregroundStyle(palette.textSecondary)
        }
    }

    private var preview: some View {
        ZStack {
            Rectangle().fill(palette.card)

            switch scanner.phase {
            case .running:
                CameraPreview(session: scanner.session)
            case .denied:
                message(L.t("Нет доступа к камере. Разреши его в «Системных настройках» → ", "No camera access. Allow it in System Settings → ")
                        + L.t("«Конфиденциальность и безопасность» → «Камера», затем открой окно заново.", "Privacy & Security → Camera, then open this window again."))
            case .failed(let text):
                message(text)
            case .idle:
                message(L.t("Запрашиваю доступ к камере…", "Requesting camera access…"))
            }

            // Рамка прицела — чтобы было понятно, куда наводить.
            CutRect(cut: UI.s(18), corners: Set(CutRect.Corner.allCases))
                .strokeBorder(palette.accent.opacity(0.7), lineWidth: 1.5)
                .padding(UI.s(34))
                .allowsHitTesting(false)
        }
        .frame(height: 280)
        .clipShape(CutRect(cut: UI.s(10)))

    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Typography.body(11.5))
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
    }
}

/// Только показ картинки. Никакой асинхронной работы и никаких правок
/// состояния — иначе они попадут в середину обсчёта раскладки.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.first?.frame = nsView.bounds
    }
}
