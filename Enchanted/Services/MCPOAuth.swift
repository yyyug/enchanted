//
//  MCPOAuth.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 12/09/2026.
//

import Foundation
import Security
import AuthenticationServices
import CryptoKit
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - Keychain storage (with UserDefaults fallback)

private enum KeychainStore {
    static let service = "com.enchanted.app.mcp"

    @discardableResult
    private static func save(_ data: Data, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil)
        }

        return updateStatus
    }

    private static func load(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private static func delete(_ account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func save<T: Codable>(_ value: T, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        if save(data, account: account) == errSecSuccess {
            return true
        }
        // Fall back to UserDefaults (e.g. when the Keychain is unavailable).
        let key = "mcp.\(account)"
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    static func load<T: Codable>(_ type: T.Type, account: String) -> T? {
        if let data = load(account), let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }
        let key = "mcp.\(account)"
        if let data = UserDefaults.standard.data(forKey: key),
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }
        return nil
    }

    static func delete(account: String) {
        delete(account)
        UserDefaults.standard.removeObject(forKey: "mcp.\(account)")
    }
}

// MARK: - Token & session stores

enum MCPTokenStore {
    static func load(serverId: UUID) -> MCPAuthToken? {
        KeychainStore.load(MCPAuthToken.self, account: "token-\(serverId.uuidString)")
    }

    static func save(token: MCPAuthToken, serverId: UUID) {
        KeychainStore.save(token, account: "token-\(serverId.uuidString)")
    }

    static func delete(serverId: UUID) {
        KeychainStore.delete(account: "token-\(serverId.uuidString)")
    }
}

enum MCPOAuthSessionStore {
    static func load(serverId: UUID) -> MCPOAuthSession? {
        KeychainStore.load(MCPOAuthSession.self, account: "session-\(serverId.uuidString)")
    }

    static func save(session: MCPOAuthSession, serverId: UUID) {
        KeychainStore.save(session, account: "session-\(serverId.uuidString)")
    }

    static func delete(serverId: UUID) {
        KeychainStore.delete(account: "session-\(serverId.uuidString)")
    }
}

// MARK: - OAuth 2.1 client

/// Performs the MCP OAuth 2.1 flow: discovery, dynamic client registration,
/// PKCE authorization code grant (via `ASWebAuthenticationSession`) and
/// refresh token renewal. Serialized on the main actor.
@MainActor
final class MCPOAuthClient: NSObject {
    static let shared = MCPOAuthClient()

    static let redirectURI = "enchanted://oauth/callback"
    private static let defaultScope = "offline_access"

    private var authSession: ASWebAuthenticationSession?
    private var activeState: String?
    private var activeCodeVerifier: String?

    private override init() {}

    /// Returns a usable access token for the given server, performing the full
    /// authorization flow when necessary.
    func obtainToken(for server: MCPServerConfig) async throws -> MCPAuthToken {
        if let loaded = MCPTokenStore.load(serverId: server.id), !loaded.isExpired {
            return loaded
        }

        if let loaded = MCPTokenStore.load(serverId: server.id),
           let refreshToken = loaded.refreshToken,
           !refreshToken.isEmpty {
            if let refreshed = try? await refresh(refreshToken: refreshToken, server: server) {
                MCPTokenStore.save(token: refreshed, serverId: server.id)
                return refreshed
            }
        }

        let token = try await authorize(server: server)
        MCPTokenStore.save(token: token, serverId: server.id)
        return token
    }

    private func authorize(server: MCPServerConfig) async throws -> MCPAuthToken {
        let session = try await discoverSession(for: server)
        let clientID = try await registerIfNeeded(session: session, server: server)

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.randomState()
        activeState = state
        activeCodeVerifier = codeVerifier

        guard let authorizationURL = buildAuthorizationURL(
            session: session,
            clientID: clientID,
            codeChallenge: codeChallenge,
            state: state
        ) else {
            throw MCPConnectionError.oauth("Could not build the authorization URL")
        }

        let callbackURL = try await presentAuthorizationUI(url: authorizationURL)

        activeCodeVerifier = nil
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw MCPConnectionError.oauth("Invalid authorization callback")
        }

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let desc = queryItems.first(where: { $0.name == "error_description" })?.value
            throw MCPConnectionError.oauth(desc ?? "Authorization failed: \(error)")
        }

        guard let returnedState = queryItems.first(where: { $0.name == "state" })?.value, returnedState == state else {
            throw MCPConnectionError.oauth("State validation failed")
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw MCPConnectionError.oauth("Authorization code missing from callback")
        }

        defer { activeState = nil }

        let token = try await exchangeCode(code: code, codeVerifier: codeVerifier, session: session, clientID: clientID)
        return token
    }

    // MARK: Discovery

    private func discoverSession(for server: MCPServerConfig) async throws -> MCPOAuthSession {
        if let cached = MCPOAuthSessionStore.load(serverId: server.id) {
            return cached
        }

        guard let resourceURL = URL(string: server.url),
              let origin = resourceURL.scheme.map({ "\($0)://\(resourceURL.host ?? "")" }),
              let originURL = URL(string: origin) else {
            throw MCPConnectionError.oauth("Invalid MCP server URL for OAuth discovery")
        }

        var authorizationServers: [URL] = []
        if let protected = try? await Self.fetchJSON(url: protectedResourceMetadataURL(for: originURL)),
           let list = protected["authorization_servers"] as? [String] {
            authorizationServers = list.compactMap { URL(string: $0) }
        }

        var asURLs = authorizationServers
        if asURLs.isEmpty {
            asURLs = [originURL]
        }

        var lastError: Error?
        for asURL in asURLs {
            let metadataURL = authorizationServerMetadataURL(for: asURL)
            do {
                let metadata = try await Self.fetchJSON(url: metadataURL)
                guard let authorizationEndpoint = metadata["authorization_endpoint"] as? String,
                      let tokenEndpoint = metadata["token_endpoint"] as? String else {
                    continue
                }
                let session = MCPOAuthSession(
                    clientID: "",
                    authorizationEndpoint: authorizationEndpoint,
                    tokenEndpoint: tokenEndpoint,
                    registrationEndpoint: metadata["registration_endpoint"] as? String,
                    revocationEndpoint: metadata["revocation_endpoint"] as? String,
                    asMetadataURL: metadataURL.absoluteString,
                    resourceURI: resourceURL.absoluteString
                )
                return session
            } catch {
                lastError = error
            }
        }

        throw MCPConnectionError.oauth(lastError?.localizedDescription ?? "OAuth authorization server metadata could not be discovered")
    }

    private func protectedResourceMetadataURL(for origin: URL) -> URL {
        origin.appendingPathComponent(".well-known/oauth-protected-resource")
    }

    private func authorizationServerMetadataURL(for asURL: URL) -> URL {
        asURL.appendingPathComponent(".well-known/oauth-authorization-server")
    }

    private static func fetchJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MCPConnectionError.oauth("Metadata request failed for \(url.absoluteString)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.oauth("Invalid metadata JSON from \(url.absoluteString)")
        }
        return json
    }

    // MARK: Dynamic registration (RFC 7591)

    private func registerIfNeeded(session: MCPOAuthSession, server: MCPServerConfig) async throws -> String {
        // Manual override takes precedence over discovery + dynamic registration.
        if let overrideClientID = server.oauthClientId?.trimmingCharacters(in: .whitespaces), !overrideClientID.isEmpty {
            let secret = server.oauthClientSecret?.trimmingCharacters(in: .whitespaces)
            if session.clientID != overrideClientID || session.clientSecret != secret {
                var updated = session
                updated.clientID = overrideClientID
                updated.clientSecret = (secret?.isEmpty == false) ? secret : nil
                MCPOAuthSessionStore.save(session: updated, serverId: server.id)
                return overrideClientID
            }
            return session.clientID
        }

        if !session.clientID.isEmpty {
            return session.clientID
        }
        guard let registrationEndpoint = session.registrationEndpoint,
              let url = URL(string: registrationEndpoint) else {
            throw MCPConnectionError.oauth("Server does not support dynamic client registration")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Enchanted",
            "redirect_uris": [Self.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 201 || statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw MCPConnectionError.oauth("Client registration failed: \(message.isEmpty ? "HTTP \(statusCode)" : message)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String else {
            throw MCPConnectionError.oauth("Client registration returned no client_id")
        }

        var updated = session
        updated.clientID = clientID
        updated.clientSecret = json["client_secret"] as? String
        MCPOAuthSessionStore.save(session: updated, serverId: server.id)
        return clientID
    }

    // MARK: Authorization UI

    private func buildAuthorizationURL(
        session: MCPOAuthSession,
        clientID: String,
        codeChallenge: String,
        state: String
    ) -> URL? {
        var components = URLComponents(string: session.authorizationEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.defaultScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    private func presentAuthorizationUI(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "enchanted"
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: MCPConnectionError.oauth("Authorization was cancelled"))
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: MCPConnectionError.oauth("Authorization completed with no callback"))
                }
            }
            self.authSession = session
#if os(iOS)
            session.presentationContextProvider = self
#endif
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: MCPConnectionError.oauth("Could not start the authorization session"))
            }
        }
    }

    // MARK: Tokens

    private func exchangeCode(
        code: String,
        codeVerifier: String,
        session: MCPOAuthSession,
        clientID: String
    ) async throws -> MCPAuthToken {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        if let secret = session.clientSecret {
            items.append(URLQueryItem(name: "client_secret", value: secret))
        }

        let data = try await Self.postForm(urlString: session.tokenEndpoint, items: items)
        let json = try Self.parseTokenJSON(data)
        guard let accessToken = json["access_token"] as? String else {
            throw MCPConnectionError.oauth("Token endpoint returned no access_token")
        }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        return MCPAuthToken(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            tokenType: json["token_type"] as? String
        )
    }

    private func refresh(refreshToken: String, server: MCPServerConfig) async throws -> MCPAuthToken {
        guard let session = MCPOAuthSessionStore.load(serverId: server.id), !session.clientID.isEmpty else {
            throw MCPConnectionError.oauth("No registered OAuth client for refresh")
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: session.clientID)
        ]
        if let secret = session.clientSecret {
            items.append(URLQueryItem(name: "client_secret", value: secret))
        }

        let data = try await Self.postForm(urlString: session.tokenEndpoint, items: items)
        let json = try Self.parseTokenJSON(data)
        guard let accessToken = json["access_token"] as? String else {
            throw MCPConnectionError.oauth("Token refresh returned no access_token")
        }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        return MCPAuthToken(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            tokenType: json["token_type"] as? String
        )
    }

    // MARK: PKCE & state helpers

    private static func parseTokenJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.oauth("Invalid token endpoint response")
        }
        if let error = json["error"] as? String {
            let desc = json["error_description"] as? String ?? ""
            throw MCPConnectionError.oauth("Token endpoint error: \(error) \(desc)")
        }
        return json
    }

    private static func postForm(urlString: String, items: [URLQueryItem]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw MCPConnectionError.oauth("Invalid token endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = items
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw MCPConnectionError.oauth("Token request failed: \(message.isEmpty ? "HTTP \(statusCode)" : message)")
        }
        return data
    }

    // MARK: PKCE & state helpers

    private static func generateCodeVerifier() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        let randomBytes = (0..<64).map { _ in UInt8.random(in: 0..<255) }
        let base64 = Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(String(base64.prefix(128)).map { characters.contains($0) ? $0 : "A" })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomState() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0..<255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
extension MCPOAuthClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}
#endif