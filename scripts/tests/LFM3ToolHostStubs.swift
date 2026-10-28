import Foundation

// The portable parser tests need only the names of repository tools; the
// real service, credentials, network and approvals are not involved.
enum GitHubWorkspaceService {
    static let toolNames: Set<String> = ["list_files", "read_file", "write_file", "audit_secret_history"]
}
