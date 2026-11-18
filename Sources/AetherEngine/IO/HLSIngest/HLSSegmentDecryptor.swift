import Foundation
import CommonCrypto

/// AES-128-CBC/PKCS7 clear-key decryption for HLS EXT-X-KEY METHOD=AES-128 segments (Pluto/Samsung-TV+ style). Not a DRM system; standard HLS client behavior.
enum HLSSegmentDecryptor {

    /// Returns nil on malformed key/IV length or CommonCrypto failure; caller treats as terminal (host falls back to server-muxed route).
    static func decryptAES128CBC(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        cbc(ciphertext, key: key, iv: iv, options: CCOptions(kCCOptionPKCS7Padding))
    }

    /// AE#1089: the plaintext of a segment's first whole blocks, for a reader that only needs its head.
    /// CBC block n depends on ciphertext blocks n-1 and n alone, so a prefix decrypts to exactly the
    /// prefix of the full plaintext. No padding is stripped, because the padding sits at the segment's
    /// end and a head never reaches it. A trailing partial block is left out.
    static func decryptAES128CBCHead(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        let whole = ciphertext.count - ciphertext.count % kCCBlockSizeAES128
        return cbc(ciphertext.prefix(whole), key: key, iv: iv, options: 0)
    }

    private static func cbc(_ ciphertext: Data, key: Data, iv: Data, options: CCOptions) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }

        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var plaintext = Data(count: outputCapacity)
        var decryptedCount = 0
        let status = plaintext.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBuf.baseAddress, kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, outputCapacity,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        plaintext.removeSubrange(decryptedCount..<plaintext.count)
        return plaintext
    }
}
