//
//  OpenAIService.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 05/09/2026.
//

import Foundation
import Combine

struct OpenAIChatResponse: ChatResponse {
    let content: String?
}

struct OpenAIModel: Codable {
    let id: String
    let object: String?
    let created: Int?
    let owned_by: String?
}

struct OpenAIModelsResponse: Codable {
    let data: [OpenAIModel]
    let object: String?
}

struct OpenAIStreamChoice: Codable {
    let delta: OpenAIDelta?
    let finish_reason: String?
    let index: Int?
}

struct OpenAIDelta: Codable {
    let content: String?
    let role: String?
}

struct OpenAIStreamResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [OpenAIStreamChoice]?
}

struct OpenAIErrorResponse: Codable {
    let error: OpenAIErrorDetail?
}

struct OpenAIErrorDetail: Codable {
    let message: String?
    let type: String?
    let code: String?
}

class OpenAIService: LLMService, @unchecked Sendable {
    static let shared = OpenAIService()

    private var baseURL: URL
    private var apiKey: String
    private var urlSession: URLSession
    private var activeTask: URLSessionDataTask?

    init() {
        let defaultURL = "https://api.openai.com/v1"
        let savedURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? defaultURL
        let savedKey = UserDefaults.standard.string(forKey: "openAIApiKey") ?? ""

        self.baseURL = URL(string: savedURL) ?? URL(string: defaultURL)!
        self.apiKey = savedKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    func configure(baseURL: String?, apiKey: String?) {
        if var url = baseURL, !url.isEmpty {
            if !url.contains("http") {
                url = "http://" + url
            }
            if let parsedURL = URL(string: url) {
                self.baseURL = parsedURL
            }
        }
        if let key = apiKey {
            self.apiKey = key
        }
    }

    func getModels() async throws -> [LanguageModel] {
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
               let message = errorResponse.error?.message {
                throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }

        let modelsResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)

        return modelsResponse.data.map { model in
            LanguageModel(
                name: model.id,
                provider: .openAI,
                imageSupport: model.id.contains("vision") || model.id.contains("gpt-4o") || model.id.contains("gpt-4")
            )
        }
    }

    func reachable() async -> Bool {
        do {
            let url = baseURL.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await urlSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    func chat(request: ChatRequest) -> AnyPublisher<any ChatResponse, Error> {
        let subject = PassthroughSubject<any ChatResponse, Error>()

        let url = baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: Any]] = []
        for message in request.messages {
            var msgDict: [String: Any] = [
                "role": message.role.rawValue,
                "content": message.content
            ]

            if let images = message.images, !images.isEmpty {
                var contentParts: [[String: Any]] = [
                    ["type": "text", "text": message.content]
                ]
                for imageBase64 in images {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)"]
                    ])
                }
                msgDict["content"] = contentParts
            }

            messages.append(msgDict)
        }

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true
        ]

        if let temp = request.temperature {
            body["temperature"] = temp
        }

        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = urlSession.dataTask(with: urlRequest) { _, _, _ in }
        self.activeTask = task

        let delegate = StreamDelegate(
            subject: subject,
            onComplete: { [weak self] in
                self?.activeTask = nil
            }
        )
        let streamSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let streamTask = streamSession.dataTask(with: urlRequest)
        streamTask.resume()

        return subject
            .handleEvents(receiveCancel: { [weak self] in
                streamTask.cancel()
                self?.activeTask = nil
            })
            .eraseToAnyPublisher()
    }
}

private class StreamDelegate: NSObject, URLSessionDataDelegate {
    let subject: PassthroughSubject<any ChatResponse, Error>
    let onComplete: () -> Void
    private var buffer = Data()

    init(subject: PassthroughSubject<any ChatResponse, Error>, onComplete: @escaping () -> Void) {
        self.subject = subject
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        let dataString = String(data: buffer, encoding: .utf8) ?? ""
        let lines = dataString.components(separatedBy: "\n")

        var processedUpTo = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data: ") {
                let jsonString = String(trimmed.dropFirst(6))

                if jsonString.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                    subject.send(completion: .finished)
                    onComplete()
                    return
                }

                if let jsonData = jsonString.data(using: .utf8),
                   let streamResponse = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: jsonData) {
                    if let content = streamResponse.choices?.first?.delta?.content {
                        subject.send(OpenAIChatResponse(content: content))
                    }
                    if streamResponse.choices?.first?.finish_reason != nil {
                        subject.send(completion: .finished)
                        onComplete()
                        return
                    }
                }
                processedUpTo = index
            }
        }

        if processedUpTo > 0 {
            let remaining = lines.suffix(from: processedUpTo + 1).joined(separator: "\n")
            buffer = Data(remaining.utf8)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                subject.send(completion: .finished)
            } else {
                subject.send(completion: .failure(error))
            }
        } else {
            subject.send(completion: .finished)
        }
        onComplete()
    }
}
