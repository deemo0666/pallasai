import Foundation

// MARK: - 新对话默认模型

struct HostModelDefault: Equatable {
    var provider: String
    var model: String
    var effort: String?
    var remember: Bool?
}

struct HostModelDefaultSettings {
    let value: HostModelDefault
    let revision: Int
    let writable: Bool
    private static let namespace = "agent-default-model"

    static func read(_ host: Harness) async throws -> Self {
        let result = try await host.rpc("settings/describe", args: [:])
        guard let section = (result["namespaces"] as? [Object])?.first(where: { $0["ns"] as? String == namespace }),
              let revision = section["revision"] as? Int, let values = section["value"] as? Object,
              let schema = section["schema"] as? Object, let root = schema["uid"] as? Int, let refs = schema["refs"] as? [String: Object],
              let fields = refs[String(root)]?["dict"] as? [String: Int],
              let provider = fields["provider"], refs[String(provider)]?["type"] as? String == "string",
              let model = fields["model"], refs[String(model)]?["type"] as? String == "string",
              let effort = fields["reasoningEffort"], refs[String(effort)]?["type"] as? String == "string" else {
            throw HostError(String(localized: "这台设备不能改默认模型。"))
        }
        var remember: Bool?
        if let field = fields["rememberLastSelection"] {
            guard refs[String(field)]?["type"] as? String == "boolean",
                  let flag = values["rememberLastSelection"] as? Bool else { throw HostError(String(localized: "这台设备不能改默认模型。")) }
            remember = flag
        }
        return Self(value: HostModelDefault(provider: values["provider"] as? String ?? "", model: values["model"] as? String ?? "",
                                            effort: values["reasoningEffort"] as? String, remember: remember),
                    revision: revision, writable: result["writable"] as? Bool == true)
    }

    func save(_ desired: HostModelDefault, on host: Harness) async throws -> Self {
        guard writable, !desired.provider.isEmpty, !desired.model.isEmpty,
              (value.remember == nil) == (desired.remember == nil) else { throw HostError(String(localized: "当前设备不能保存这项设置。")) }
        var ops: [Object] = [["op": "set", "path": ["provider"], "value": desired.provider],
                             ["op": "set", "path": ["model"], "value": desired.model]]
        if let effort = desired.effort { ops.append(["op": "set", "path": ["reasoningEffort"], "value": effort]) }
        else { ops.append(["op": "unset", "path": ["reasoningEffort"]]) }
        if let remember = desired.remember { ops.append(["op": "set", "path": ["rememberLastSelection"], "value": remember]) }
        _ = try await host.rpc("settings/mutate", args: ["ns": Self.namespace, "expectedRevision": revision, "ops": ops])
        let confirmed = try await Self.read(host)
        guard confirmed.value == desired else { throw HostError(String(localized: "设备上的默认设置和你选的不一样，重新加载后再看。")) }
        return confirmed
    }
}
