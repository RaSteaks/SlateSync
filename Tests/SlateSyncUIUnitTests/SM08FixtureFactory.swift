import SlateSyncDomain

/// Deterministic SM08 scale fixtures contain the adverse values promised by
/// fixture-manifest.json instead of measuring only homogeneous short rows.
enum SM08FixtureFactory {
    static func resolveCSV(rowCount: Int = 10_000) -> ResolveCSVTable {
        let statuses = ["好", "保", ""]
        let rows = (0..<rowCount).map { index in
            let filename: String = switch index {
            case 0: "中文 场记 🎬.mov"
            case 42, 43: "DUPLICATE-A0042.mov"
            default: String(format: "A%05d.mov", index)
            }
            let comments: String = switch index {
            case 0: "zhongwen 中文 IME 🎬"
            case 1: ""
            case 2: String(repeating: "长字段", count: 160)
            default: index.isMultiple(of: 97) ? "复核" : ""
            }
            return [
                filename,
                comments,
                index.isMultiple(of: 113) ? "" : "\(index / 100)",
                "\(index % 100)",
                "\((index % 9) + 1)",
                statuses[index % statuses.count],
                index.isMultiple(of: 2) ? "24" : "23.976",
            ]
        }
        return ResolveCSVTable(
            headers: ["文件名", "注释", "场", "镜", "次", "状态", "帧率"],
            rows: rows,
            format: .init()
        )
    }
}
