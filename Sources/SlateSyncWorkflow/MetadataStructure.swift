import Foundation
import SlateSyncDomain

/// Filesystem-independent naming convention learning used by the bounded
/// scanner to report reusable camera-sidecar naming conventions. Discovery
/// still enumerates each matching directory so conflicting copies stay visible.
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
