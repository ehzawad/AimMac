import Foundation
import CryptoKit

/// This Mac's long-term pairing key, kept in a file only this user can read.
enum MacIdentity {
    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OrbitPointer", isDirectory: true).appendingPathComponent("identity.key")
    }

    static func loadOrCreate() -> Curve25519.Signing.PrivateKey {
        let url = file
        if let raw = try? Data(contentsOf: url),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Created empty and private first, so the key is never briefly world-readable.
            _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try key.rawRepresentation.write(to: url)
        } catch {
            NSLog("Orbit Pointer: could not save the pairing key: \(error)")
        }
        return key
    }
}
