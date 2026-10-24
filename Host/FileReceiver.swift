import Foundation

/// Receives files pushed from the client and writes them into ~/Downloads/Oriel.
///
/// One transfer at a time, chunks appended in order. The filename is reduced to
/// its last path component so a crafted name cannot escape the destination
/// directory, and an existing file is never overwritten.
final class FileReceiver {

    private struct Transfer {
        let url: URL
        let handle: FileHandle
        let expected: Int
        var received: Int
    }

    private var transfer: Transfer?
    var onLog: ((String) -> Void)?

    private var destinationDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let directory = downloads.appendingPathComponent("Oriel", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func begin(_ offer: FileOffer) {
        finish()

        let safeName = Self.sanitise(offer.name)
        var url = destinationDirectory.appendingPathComponent(safeName)

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            url = destinationDirectory.appendingPathComponent(candidate)
            counter += 1
        }

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            onLog?("Could not create \(url.lastPathComponent)")
            return
        }

        transfer = Transfer(url: url, handle: handle, expected: offer.size, received: 0)
        onLog?("Receiving \(url.lastPathComponent) (\(offer.size) bytes)")
    }

    func append(offset: Int, data: Data) {
        guard var current = transfer else { return }
        if offset != current.received {
            onLog?("File chunk out of order: expected \(current.received), got \(offset)")
        }
        do {
            try current.handle.write(contentsOf: data)
        } catch {
            onLog?("Write failed: \(error.localizedDescription)")
            finish()
            return
        }
        current.received += data.count
        transfer = current
    }

    func finish() {
        guard let current = transfer else { return }
        try? current.handle.close()
        transfer = nil

        let attributes = try? FileManager.default.attributesOfItem(atPath: current.url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? current.received
        onLog?("Saved \(current.url.lastPathComponent) (\(size) bytes) to \(current.url.deletingLastPathComponent().path)")
    }

    private static func sanitise(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "file" : cleaned
    }
}
