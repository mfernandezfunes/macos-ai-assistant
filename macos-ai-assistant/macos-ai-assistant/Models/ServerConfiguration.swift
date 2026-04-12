import Foundation

struct ServerConfiguration {
    var host: String
    var port: Int

    static let `default` = ServerConfiguration(host: "127.0.0.1", port: 11535)

    var url: String { "http://\(host):\(port)" }
    var openaiBaseURL: String { "\(url)/v1" }
    var chatCompletionsEndpoint: String { "\(url)/v1/chat/completions" }
}
