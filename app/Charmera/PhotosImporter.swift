import Foundation

enum PhotosImporter {
    static func importFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let posixFiles = paths.map { "POSIX file \"\($0)\"" }.joined(separator: ", ")

        let script = """
        tell application "Photos"
            if not (exists album "Charmera") then
                make new album named "Charmera"
            end if
            set theAlbum to album "Charmera"
            import {\(posixFiles)} into theAlbum skip check duplicates yes
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[PhotosImporter] AppleScript error: \(error)")
            }
        }
    }
}
