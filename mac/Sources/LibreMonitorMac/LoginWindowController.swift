import AppKit
import SwiftUI

/// Sign-in for the follower account. Validates the login immediately, so a typo is reported here.
struct LoginView: View {
    let signIn: (String, String) async -> String?
    let quit: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LibreLinkUp follower account")
                .font(.headline)

            Text("Use the second account that follows you in LibreLinkUp, not your main LibreLink login. "
                + "The password is stored in your Mac's Keychain.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // There is no website sign-up: the account is created inside the LibreLinkUp app, after an invitation from LibreLink.
            // The markdown link opens in the default browser.
            Text("**You need a LibreLinkUp account.** There is no website sign-up. In LibreLink, open "
                + "Connected apps > LibreLinkUp and invite an email address, then install the LibreLinkUp app on a "
                + "phone and create the account there with that email. More information at "
                + "[www.librelinkup.com](https://www.librelinkup.com).")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            if let errorText {
                Text(errorText)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Quit") { quit() }
                Button("Sign in") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func submit() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            errorText = "Enter both the email and the password."
            return
        }

        busy = true
        errorText = nil
        Task {
            let problem = await signIn(trimmedEmail, password)
            errorText = problem
            busy = false
        }
    }
}

@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onCancel: () -> Void
    private var finished = false

    init(signIn: @escaping (String, String) async -> String?, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init()

        let hosting = NSHostingController(rootView: LoginView(signIn: signIn, quit: onCancel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        finished = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { onCancel() } // closing the dialog without signing in quits, as on Windows
    }
}
