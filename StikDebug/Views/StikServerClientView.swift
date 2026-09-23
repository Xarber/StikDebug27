//
//  StikServerClientView.swift
//  StikDebug
//

import SwiftUI
import WebKit

struct StikServerClientView: View {
    let serverAddress: String
    let token: String

    @State private var reloadID = UUID()
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let url = Self.serverURL(from: serverAddress, token: token) {
                StikServerWebView(url: url, errorMessage: $errorMessage)
                    .id(reloadID)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "Invalid StikServer Address",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Paste the complete remote access link from the StikServer desktop app.")
                )
            }
        }
        .navigationTitle("StikServer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    errorMessage = nil
                    reloadID = UUID()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        }
        .alert("StikServer Connection", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Retry") { errorMessage = nil; reloadID = UUID() }
            Button("Cancel", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private static func serverURL(from value: String, token: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)") else {
            return nil
        }
        guard components.scheme == "http" || components.scheme == "https",
              components.host != nil else { return nil }
        if components.path.isEmpty { components.path = "/" }
        if !token.isEmpty, components.queryItems?.contains(where: { $0.name == "token" }) != true {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "token", value: token))
            components.queryItems = queryItems
        }
        return components.url
    }
}

private struct StikServerWebView: UIViewRepresentable {
    let url: URL
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(errorMessage: $errorMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url, !webView.isLoading else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var errorMessage: String?

        init(errorMessage: Binding<String?>) {
            _errorMessage = errorMessage
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            errorMessage = "StikDebug could not reach StikServer. Confirm the desktop app is open and both devices can reach the same private network.\n\n\(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            errorMessage = error.localizedDescription
        }
    }
}
