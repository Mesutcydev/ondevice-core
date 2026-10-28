import Combine
import CommonCrypto
import Foundation
import Security
import UIKit

/// A separate, device-only credential. Clearing app preferences or chat history
/// deliberately does not remove it. There is no device-passcode/PIN reset shortcut.
@MainActor
protocol ParentalControlStorage {
    func read() throws -> Data?
    func write(_ data: Data?) throws
}

@MainActor
final class ParentalControlKeychain: ParentalControlStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.token.TokenAI.parental-controls",
         kSecAttrAccount as String: "parent-pin-v1"]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ParentalControlManager.Failure.storageUnavailable
        }
        return data
    }

    func write(_ data: Data?) throws {
        if let data {
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw ParentalControlManager.Failure.storageUnavailable }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ParentalControlManager.Failure.storageUnavailable
            }
        }
    }
}

@MainActor
final class ParentalControlManager: ObservableObject {
    static let shared = ParentalControlManager(storage: ParentalControlKeychain())

    enum Failure: LocalizedError {
        case invalidPIN, mismatch, incorrectPIN, locked(Date), storageUnavailable, alreadyConfigured, notConfigured
        var errorDescription: String? {
            switch self {
            case .invalidPIN: return String(localized: "Use a six-digit PIN containing only numbers 0–9.")
            case .mismatch: return String(localized: "The new PINs do not match.")
            case .incorrectPIN: return String(localized: "Incorrect parent PIN.")
            case .locked(let date): return String(localized: "Too many attempts. Try again after \(date.formatted(date: .omitted, time: .shortened)).")
            case .storageUnavailable: return String(localized: "Secure storage is unavailable. Image generation stays restricted until it can be read safely.")
            case .alreadyConfigured: return String(localized: "Parental controls are already configured.")
            case .notConfigured: return String(localized: "Set a parent PIN first.")
            }
        }
    }

    private struct Record: Codable {
        var version = 1
        var salt: Data
        var derivedPIN: Data
        var rounds: UInt32 = 600_000
        var blocksImages = true
        var failedAttempts = 0
        var lockedUntil: Date?
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var blocksImageGeneration = false
    @Published private(set) var storageUnavailable = false
    var imageGenerationRestriction: String? {
        guard blocksImageGeneration else { return nil }
        return storageUnavailable ? Failure.storageUnavailable.localizedDescription
            : String(localized: "Image generation is restricted by parental controls. A parent can change this in Settings → Parental controls.")
    }
    private let storage: any ParentalControlStorage
    private let now: () -> Date
    private var record: Record?
    private var foregroundObserver: AnyCancellable?

    init(storage: any ParentalControlStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        reload()
        foregroundObserver = NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.reload() }
    }

    /// Re-read on foregrounding so locked/protected Keychain access can recover.
    func reload() {
        do {
            let data = try storage.read()
            let value = try data.map { try JSONDecoder().decode(Record.self, from: $0) }
            if let value {
                guard value.version == 1, value.salt.count == 32, value.derivedPIN.count == 32,
                      value.rounds == 600_000, (0...1_000).contains(value.failedAttempts) else {
                    throw Failure.storageUnavailable
                }
            }
            record = value
            storageUnavailable = false
            publish()
        } catch { failClosed() }
    }

    func configure(pin: String, confirmation: String) throws {
        guard !storageUnavailable else { throw Failure.storageUnavailable }
        guard record == nil else { throw Failure.alreadyConfigured }
        try validateNewPIN(pin, confirmation: confirmation)
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.storageUnavailable }
        let value = Record(salt: salt, derivedPIN: try derive(pin, salt: salt))
        try persist(value)
    }

    func setImageRestriction(_ restricted: Bool, pin: String) throws {
        var value = try authenticate(pin)
        value.blocksImages = restricted
        try persist(value)
    }

    func changePIN(current: String, new: String, confirmation: String) throws {
        var value = try authenticate(current)
        try validateNewPIN(new, confirmation: confirmation)
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw Failure.storageUnavailable
        }
        value.salt = salt
        value.derivedPIN = try derive(new, salt: salt)
        try persist(value)
    }

    func remove(pin: String) throws {
        _ = try authenticate(pin)
        try persist(nil)
    }

    private func authenticate(_ pin: String) throws -> Record {
        guard !storageUnavailable else { throw Failure.storageUnavailable }
        guard var value = record else { throw Failure.notConfigured }
        if let until = value.lockedUntil, until > now() { throw Failure.locked(until) }
        let validFormat = pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) }
        let candidate = validFormat ? try derive(pin, salt: value.salt) : Data(repeating: 0, count: 32)
        // Constant-time comparison, even for an invalid input format.
        let difference = zip(candidate, value.derivedPIN).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard validFormat && difference == 0 else {
            value.failedAttempts = min(value.failedAttempts + 1, 1_000)
            if value.failedAttempts >= 5 {
                let exponent = min(value.failedAttempts - 5, 6)
                value.lockedUntil = now().addingTimeInterval(min(3_600, 60 * pow(2, Double(exponent))))
            }
            try persist(value) // A restart must not erase the retry limit.
            if let until = value.lockedUntil, until > now() { throw Failure.locked(until) }
            throw Failure.incorrectPIN
        }
        value.failedAttempts = 0
        value.lockedUntil = nil
        return value
    }

    private func validateNewPIN(_ pin: String, confirmation: String) throws {
        guard pin.utf8.count == 6, pin.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.invalidPIN }
        guard pin == confirmation else { throw Failure.mismatch }
    }

    private func derive(_ pin: String, salt: Data) throws -> Data {
        var result = Data(count: 32)
        let bytes = Array(pin.utf8)
        let status = bytes.withUnsafeBytes { password in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        password.bindMemory(to: Int8.self).baseAddress, bytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        output.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.storageUnavailable }
        return result
    }

    private func persist(_ value: Record?) throws {
        do {
            try storage.write(try value.map { try JSONEncoder().encode($0) })
            record = value
            storageUnavailable = false
            publish()
        } catch {
            failClosed()
            throw Failure.storageUnavailable
        }
    }

    private func publish() {
        isEnabled = record != nil
        blocksImageGeneration = record?.blocksImages ?? false
    }

    private func failClosed() {
        storageUnavailable = true
        isEnabled = true
        blocksImageGeneration = true
    }
}
