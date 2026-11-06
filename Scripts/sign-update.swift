// Подпись архива обновления ключом издателя Life VPN (Ed25519).
//
//   UPDATE_SIGNING_KEY=<base64 32 байта> swift Scripts/sign-update.swift <продукт> <версия> <sha256>
//
// Печатает подпись в base64. Формат подписываемой строки совпадает с
// UpdateSignature.message в Sources/LifeVPN/Core/Updater.swift.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyB64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let raw = Data(base64Encoded: keyB64),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("usage: UPDATE_SIGNING_KEY=… sign-update.swift <product> <version> <sha256>\n".utf8))
    exit(2)
}
let message = Data("LifeVPN-update-v1\n\(args[1])\n\(args[2])\n\(args[3].lowercased())\n".utf8)
let signature = try key.signature(for: message)
print(signature.base64EncodedString())
