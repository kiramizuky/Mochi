import Foundation
import JavaScriptCore

/// JavaScriptCore engine untuk menjalankan logika node secara aman.
/// JS tidak punya akses file system atau network langsung — semua I/O
/// dijalankan lewat Swift dan dilewatkan ke JS sebagai variabel.
final class NodeEngine: @unchecked Sendable {
    private let context: JSContext
    private let lock = NSLock()
    private var lastException: String?

    init() {
        self.context = JSContext()
        self.context.exceptionHandler = { _, value in
            self.lastException = value?.toString() ?? "JavaScript error"
        }
    }

    /// Terapkan pesan pengecualian JavaScript terakhir (jika ada), atau nil.
    var lastJSException: String? { lastException }

    /// Evaluasi skrip JS dengan variabel yang diinjeksikan. Mengembalikan JSValue atau nil
    /// saat skrip melempar pengecualian (lihat `lastJSException` untuk alasannya).
    func evaluate(_ script: String, variables: [String: Any]) -> JSValue? {
        lock.lock()
        defer { lock.unlock() }

        lastException = nil
        for (key, value) in variables {
            context.setObject(value, forKeyedSubscript: key as NSString)
        }
        return context.evaluateScript(script)
    }

    /// Panggil fungsi JS dengan nama beserta argumen.
    func callFunction(_ name: String, arguments: [Any]) -> JSValue? {
        lock.lock()
        defer { lock.unlock() }

        return context.objectForKeyedSubscript(name)
    }

    /// Konversi JSValue ke JSONValue agar dapat diproses Swift.
    func toJSONValue(_ jsValue: JSValue?) -> JSONValue {
        guard let jsValue else { return .null }
        if jsValue.isNull || jsValue.isUndefined { return .null }
        if jsValue.isBoolean { return .bool(jsValue.toBool()) }
        if jsValue.isNumber { return .number(jsValue.toDouble()) }
        if jsValue.isString { return .string(jsValue.toString() ?? "") }
        if jsValue.isArray {
            let arr = jsValue.toArray() ?? []
            return .array(arr.map { jsonValue(from: $0) })
        }
        if jsValue.isObject {
            let dict = jsValue.toDictionary() as? [String: Any] ?? [:]
            return .object(dict.mapValues { jsonValue(from: $0) })
        }
        return .null
    }

    private func jsonValue(from any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return .bool(n.boolValue)
        case let n as NSNumber: return .number(n.doubleValue)
        case let a as [Any]: return .array(a.map(jsonValue(from:)))
        case let d as [String: Any]: return .object(d.mapValues(jsonValue(from:)))
        default: return .null
        }
    }
}
