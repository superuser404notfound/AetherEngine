import XCTest
@testable import AetherEngineSMB

final class SMBURLTests: XCTestCase {
    func testParsesUserPassHostShareAndPath() throws {
        let u = try SMBURL.parse("smb://alice:s3cret@nas.local/media/Movies/film.mkv")
        XCTAssertEqual(u.server.absoluteString, "smb://nas.local")
        XCTAssertEqual(u.user, "alice")
        XCTAssertEqual(u.password, "s3cret")
        XCTAssertEqual(u.share, "media")
        XCTAssertEqual(u.path, "Movies/film.mkv")
    }

    func testEmptyUserWhenNoCredentials() throws {
        // An omitted username parses to empty, SMBConnection.connect maps that
        // to the guest-then-anonymous fallback; the parser must not fabricate
        // "guest" or that fallback would never fire.
        let u = try SMBURL.parse("smb://nas.local/public/clip.mp4")
        XCTAssertEqual(u.user, "")
        XCTAssertEqual(u.password, "")
        XCTAssertEqual(u.share, "public")
        XCTAssertEqual(u.path, "clip.mp4")
    }

    func testRejectsNonSmbScheme() {
        XCTAssertThrowsError(try SMBURL.parse("http://nas.local/x/y"))
    }

    /// Audit NET-209: the scheme is case-insensitive, and an error never repeats a password.
    func testUppercaseSchemeParses() throws {
        let u = try SMBURL.parse("SMB://user:secret@nas/share/movie.mkv")
        XCTAssertEqual(u.share, "share")
        XCTAssertEqual(u.password, "secret")
    }

    func testErrorDoesNotRepeatThePassword() {
        XCTAssertThrowsError(try SMBURL.parse("http://user:hunter2@nas/share/movie.mkv")) { error in
            XCTAssertFalse(error.localizedDescription.contains("hunter2"))
            XCTAssertTrue(error.localizedDescription.contains("not an smb:// URL"))
        }
    }

    func testRejectsMissingFilePath() {
        XCTAssertThrowsError(try SMBURL.parse("smb://nas.local/onlyshare"))
    }

    /// AE#283: hosts render a caught error with `localizedDescription`. Without LocalizedError
    /// conformance that answers "The operation couldn't be completed. (ParseError error 1.)" and the
    /// parser's message, the only thing that says what is wrong with the URL, never reaches the user.
    func testParseErrorCarriesItsMessage() {
        XCTAssertThrowsError(try SMBURL.parse("http://nas.local/x/y")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not an smb:// URL"),
                          "unexpected rendering: \(error.localizedDescription)")
            XCTAssertEqual(error.localizedDescription, String(describing: error))
        }
    }

    func testSMBErrorCarriesItsMessage() {
        let error: any Error = SMBConnection.SMBError(message: "share not found")
        XCTAssertTrue(error.localizedDescription.contains("share not found"),
                      "unexpected rendering: \(error.localizedDescription)")
        XCTAssertEqual(error.localizedDescription, String(describing: error))
    }
}
