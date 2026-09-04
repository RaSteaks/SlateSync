import Foundation
import SlateSyncDomain

/// Filesystem-independent naming convention learning used by the bounded
/// scanner to avoid enumerating every recognized clip directory.
public enum MetadataStructure {
    public static func defaultTemplates() -> [MetadataNameTemplate] { [.dirnameSuffix("-slate.txt")] }

    public static func learn(directoryName: String, metadataFileNames: [String]) -> [MetadataNameTemplate] {
        metadataFileNames.map { name in
            name.hasPrefix(directoryName)
                ? .dirnameSuffix(String(name.dropFirst(directoryName.count)))
                : .fixedName(name)
        }
    }

    public static func probeNames(_ templates: [MetadataNameTemplate], directoryName: String) -> [String] {
        templates.map { template in
            switch template {
            case let .dirnameSuffix(suffix): directoryName + suffix
            case let .fixedName(name): name
            }
        }
    }
}
