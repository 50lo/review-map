import Foundation

// reviewmap-swift-helper: one long-lived process that the Review Map app starts and stops. It reads one JSON
// request per line on stdin and writes JSON lines on stdout, so parsing a change is one process, not one per file.
//
//   {"id":1,"op":"version"}
//     -> {"id":1,"version":"…","done":true}
//   {"id":2,"op":"parse","files":[{"key":"<blob id>","path":"a/B.swift","source":"…"}]}
//     -> {"id":2,"key":"<blob id>","file":{…}} per file, in any order, then {"id":2,"done":true}
//   {"id":3,"op":"index","index":{…IndexRequest…}}
//     -> {"id":3,"path":"a/B.swift","refs":[[line,"target file",target line,"name"],…]} per file with index
//        data, then {"id":3,"done":true}
//
// A request that fails ends with {"id":…,"done":true,"error":"…"}. Standard error carries diagnostics only.

struct ParseInput: Codable {
    var key: String
    var path: String
    var source: String
}

struct Request: Codable {
    var id: Int
    var op: String
    var files: [ParseInput]?
    var index: IndexRequest?
}

let output = FileHandle.standardOutput
let outputLock = NSLock()

func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    outputLock.lock()
    output.write(data)
    outputLock.unlock()
}

func sendEncoded<T: Encodable>(id: Int, key: String, file: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let body = try? encoder.encode(file), let keyData = try? JSONSerialization.data(withJSONObject: [key]) else { return }
    // {"id":N,"key":"…","file":<body>} without decoding the body again.
    var data = Data("{\"id\":\(id),\"key\":".utf8)
    data.append(keyData.dropFirst().dropLast())
    data.append(Data(",\"file\":".utf8))
    data.append(body)
    data.append(Data("}\n".utf8))
    outputLock.lock()
    output.write(data)
    outputLock.unlock()
}

let decoder = JSONDecoder()
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else {
        send(["id": -1, "done": true, "error": "The request is not valid JSON for this helper."])
        continue
    }
    switch request.op {
    case "version":
        send(["id": request.id, "version": helperVersion, "done": true])
    case "parse":
        let files = request.files ?? []
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let input = files[i]
            let parsed = SwiftExtractor.parse(path: input.path, source: input.source)
            sendEncoded(id: request.id, key: input.key, file: parsed)
        }
        send(["id": request.id, "done": true])
    case "index":
        guard let index = request.index else {
            send(["id": request.id, "done": true, "error": "The index request has no index field."])
            continue
        }
        do {
            try IndexReader.read(index) { path, refs in
                send(["id": request.id, "path": path, "refs": refs.map { [$0.line, $0.targetFile, $0.targetLine, $0.name] as [Any] }])
            }
            send(["id": request.id, "done": true])
        } catch {
            send(["id": request.id, "done": true, "error": "\(error)"])
        }
    default:
        send(["id": request.id, "done": true, "error": "Unknown op \(request.op)."])
    }
}
