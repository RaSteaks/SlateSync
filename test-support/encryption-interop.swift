// Independent CryptoKit oracle for synthetic Node interoperability fixtures.
import Foundation
import CryptoKit
let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: String]
let key = SymmetricKey(data: Data(base64Encoded: input["key"]!)!)
let bytes = Data(base64Encoded: input["data"]!)!
let header = Data("SLATESYNC-AES-GCM-1\n\(input["id"]!)\n".utf8)
let output: Data
if input["mode"] == "seal" {
    output = header + (try AES.GCM.seal(bytes, using: key, authenticating: header).combined!)
} else {
    output = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes.dropFirst(header.count)), using: key, authenticating: bytes.prefix(header.count))
}
print(output.base64EncodedString())
