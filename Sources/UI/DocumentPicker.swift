import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// File picker that hands back readable URLs.
///
/// Why not SwiftUI's `.fileImporter`: it returns security-scoped URLs, and when the
/// chosen file lives in iCloud Drive and has not been downloaded yet the copy fails —
/// silently, because the completion gives no reason. `UIDocumentPickerViewController`
/// with `asCopy: true` asks the system to place a copy inside our container first, so
/// what comes back is a plain readable file with no scope dance. Every outcome is
/// logged, because "nothing happened" is not a useful report.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .data, .propertyList, .xml],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            DiagLog.shared.note("picker: chose \(urls.count) file(s)")
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                DiagLog.shared.log("picker: \(url.lastPathComponent) · \(size) bytes "
                                   + "· \(url.pathExtension.isEmpty ? "no extension" : url.pathExtension)")
            }
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DiagLog.shared.log("picker: cancelled")
        }
    }
}
