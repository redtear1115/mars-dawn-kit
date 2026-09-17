#if os(macOS)
/// The released version of the `marsdawn` command-line tool.
///
/// SwiftPM gives a target no way to read the package's own tag, and Homebrew builds from a
/// tarball with no git metadata, so the number lives here and a release bumps it. It is the
/// string `marsdawn --version` prints, and the Homebrew formula compares it against its own
/// `version`; see RELEASING.md.
enum MarsDawnCLI {
    static let version = "0.3.0"
}
#endif
