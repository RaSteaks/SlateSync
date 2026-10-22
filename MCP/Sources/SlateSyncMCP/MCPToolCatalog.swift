import MCP

/// Protocol schemas describe business inputs; filesystem and network grants
/// are enforced by the service, never inferred from MCP annotation hints.
public enum MCPToolCatalog {
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        .object(["type": "object", "properties": .object(properties),
                 "required": .array(required.map(Value.string)), "additionalProperties": false])
    }
    private static func array(_ item: Value, maximum: Int) -> Value {
        .object(["type": "array", "items": item, "maxItems": .int(maximum)])
    }
    private static let nullableString: Value = .object(["type": ["string", "null"]])
    private static let record = object([
        "cardNumber": nullableString, "videoCode": nullableString,
        "scene": nullableString, "shot": nullableString, "take": nullableString,
        "takeStatus": .object(["enum": ["过", "保", "废条", .null]]),
        "goodTake": .object(["type": ["boolean", "null"]]), "comments": nullableString,
        "reviewRequiredFields": array(.stringSchema, maximum: 20)
    ])
    private static let metadata = object([
        "materialKey": string("Canonical camera:reel:clip key, e.g. A:1:15."),
        "sensorFps": nullableString, "shootDay": nullableString, "sourceName": nullableString,
        "clipName": nullableString
    ], required: ["materialKey"])
    private static let edit = object([
        "rowIndex": .object(["type": "integer", "minimum": 0]),
        "columnIndex": .object(["type": "integer", "minimum": 0]),
        "value": .stringSchema
    ], required: ["rowIndex", "columnIndex", "value"])
    private static let resolve = object([
        "fieldFormats": object(["scene": .stringSchema, "shot": .stringSchema, "take": .stringSchema],
                               required: ["scene", "shot", "take"]),
        "comments": object(["goodTake": .stringSchema, "holdTake": .stringSchema], required: ["goodTake", "holdTake"])
    ])

    public static let tools: [Tool] = {
        let merge: [String: Value] = [
            "csvPath": string("Absolute path of the original Resolve CSV."),
            "records": array(record, maximum: 20_000),
            "metadata": array(metadata, maximum: 20_000),
            "edits": array(edit, maximum: 50_000),
            "resolve": resolve,
            "offset": .object(["type": "integer", "minimum": 0]),
            "limit": .object(["type": "integer", "minimum": 1, "maximum": 200])
        ]
        func tool(_ name: String, _ description: String, _ properties: [String: Value], _ required: [String],
                  writes: Bool = false, external: Bool = false) -> Tool {
            Tool(name: name, description: description, inputSchema: object(properties, required: required),
                 annotations: .init(readOnlyHint: !writes && !external, destructiveHint: false,
                                    idempotentHint: !external, openWorldHint: external))
        }
        return [
            tool("slatesync_list_models", "List locally configured recognition models. Does not query providers or return credentials.", [:], []),
            tool("slatesync_recognize", "Recognize a PDF/image using local OCR and the configured visual provider. Sends page images and OCR evidence to that provider and may incur API charges. Requires --allow-model-requests. Returns records without changing the desktop project library.", [
                "path": string("Absolute PDF/image path (20 MiB, at most 20 pages)."),
                "providerID": .stringSchema, "modelID": .stringSchema,
                "accuracyMode": .object(["enum": ["standard", "high"]]),
                "customPrompt": .stringSchema, "slateCSVPath": .stringSchema, "resolve": resolve
            ], ["path"], external: true),
            tool("slatesync_import_slate_csv", "Parse a local UTF-8 slate CSV into records suitable for preview/export, without model calls.", [
                "path": .stringSchema
            ], ["path"]),
            tool("slatesync_scan_metadata", "Scan supported slate.txt sidecars for the current Resolve CSV material set. Returns metadata, missing keys and warnings; does not modify media.", [
                "csvPath": .stringSchema, "directoryPath": .stringSchema,
                "edits": array(edit, maximum: 50_000)
            ], ["csvPath", "directoryPath"]),
            tool("slatesync_preview_merge", "Reconcile records and optional sidecars against the original Resolve CSV. Always returns diagnostics, even when export is blocked. Rows, changes, statuses and warnings are paginated with offset/limit.", merge, ["csvPath", "records"]),
            tool("slatesync_export_csv", "Create a NEW Resolve CSV using the same merge as preview. Existing files are never overwritten. Review issues require explicit allowWarnings=true after inspecting preview. Complete matched records or manual edits are still required.", merge.merging([
                "outputPath": .stringSchema, "allowWarnings": .object(["type": "boolean"])
            ]) { _, new in new }, ["csvPath", "records", "outputPath"], writes: true)
        ]
    }()
}

private extension Value {
    static var stringSchema: Value { .object(["type": "string"]) }
}
