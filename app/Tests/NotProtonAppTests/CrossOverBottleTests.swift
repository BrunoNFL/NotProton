import Foundation
import Testing

@testable import NotProtonApp

@Suite("CrossOver bottles and external VAC linking")
struct CrossOverBottleTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-bottle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("CrossOver bottles are scanned with Windows Steam and Preview detection")
    func scansBottlesAndDetectsWindowsSteamAndPreview() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottlesDir = root.appending(path: "Bottles")
        let steamAppsDir = root.appending(path: "steamapps")

        // Bottle 1: Release bottle with Windows Steam
        let bottle1 = bottlesDir.appending(path: "Steam")
        try write("[Bottle]\n\"Description\" = \"Steam Bottle\"\n", to: bottle1.appending(path: "cxbottle.conf"))
        try write("MZ", to: bottle1.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe"))

        // Bottle 2: Preview bottle without Windows Steam
        let bottle2 = bottlesDir.appending(path: "Mirror_s Edge")
        try write("[Bottle]\n\"Preview\" = \"1\"\n", to: bottle2.appending(path: "cxbottle.conf"))

        let bottles = PrefixStore.crossOverBottles(root: bottlesDir, steamApps: steamAppsDir)
        #expect(bottles.count == 2)

        let steamBottle = bottles.first { $0.name == "Steam" }
        #expect(steamBottle != nil)
        #expect(steamBottle?.hasWindowsSteam == true)
        #expect(steamBottle?.isPreview == false)

        let previewBottle = bottles.first { $0.name == "Mirror_s Edge" }
        #expect(previewBottle != nil)
        #expect(previewBottle?.hasWindowsSteam == false)
        #expect(previewBottle?.isPreview == true)
    }

    @Test("Steam games in bottle are parsed from appmanifest files")
    func parsesBottleSteamApps() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = root.appending(path: "Bottles/Steam")
        let steamAppsDir = root.appending(path: "steamapps")

        try write("[Bottle]\n", to: bottle.appending(path: "cxbottle.conf"))
        try write("MZ", to: bottle.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe"))

        let manifest730 = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/appmanifest_730.acf")
        try write(
            """
            "AppState"
            {
            \t"appid"\t\t"730"
            \t"name"\t\t"Counter-Strike 2"
            \t"installdir"\t\t"Counter-Strike Global Offensive"
            }
            """, to: manifest730)

        let bottles = PrefixStore.crossOverBottles(root: root.appending(path: "Bottles"), steamApps: steamAppsDir)
        let steamBottle = try #require(bottles.first { $0.name == "Steam" })

        #expect(steamBottle.installedApps.count == 1)
        let cs2 = try #require(steamBottle.installedApps.first)
        #expect(cs2.appID == "730")
        #expect(cs2.name == "Counter-Strike 2")
        #expect(cs2.installdir == "Counter-Strike Global Offensive")
        #expect(cs2.isLinked == false)
    }

    @Test("Linking a bottle app creates symlinks for manifest and game directory")
    func linksAndUnlinksBottleApp() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottlesDir = root.appending(path: "Bottles")
        let bottle = bottlesDir.appending(path: "Steam")
        let steamAppsDir = root.appending(path: "steamapps")

        try write("[Bottle]\n", to: bottle.appending(path: "cxbottle.conf"))
        try write("MZ", to: bottle.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe"))

        let manifestURL = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/appmanifest_730.acf")
        try write(
            """
            "AppState"
            {
            \t"appid"\t\t"730"
            \t"name"\t\t"Counter-Strike 2"
            \t"installdir"\t\t"Counter-Strike Global Offensive"
            }
            """, to: manifestURL)

        let gameDir = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common/Counter-Strike Global Offensive")
        try write("cs2-binary-data", to: gameDir.appending(path: "game/bin/win64/cs2.exe"))

        var bottles = PrefixStore.crossOverBottles(root: bottlesDir, steamApps: steamAppsDir)
        let b = try #require(bottles.first)
        let app = try #require(b.installedApps.first)

        // 1. Link to macOS Steam
        try PrefixStore.linkBottleApp(app, from: b, steamApps: steamAppsDir)

        let dstManifest = steamAppsDir.appending(path: "appmanifest_730.acf")
        let dstGame = steamAppsDir.appending(path: "common/Counter-Strike Global Offensive")

        #expect(FileManager.default.fileExists(atPath: dstManifest.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: dstGame.path(percentEncoded: false)))

        let isManifestLink = (try? dstManifest.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
        let isGameLink = (try? dstGame.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
        #expect(isManifestLink == true)
        #expect(isGameLink == true)

        // Verify rescan sees it as linked
        bottles = PrefixStore.crossOverBottles(root: bottlesDir, steamApps: steamAppsDir)
        #expect(bottles.first?.installedApps.first?.isLinked == true)

        // 2. Unlink from macOS Steam
        try PrefixStore.unlinkBottleApp(appID: "730", installdir: "Counter-Strike Global Offensive", steamApps: steamAppsDir)

        #expect(!FileManager.default.fileExists(atPath: dstManifest.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: dstGame.path(percentEncoded: false)))

        // Original bottle game files remain intact
        #expect(FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: gameDir.appending(path: "game/bin/win64/cs2.exe").path(percentEncoded: false)))

        bottles = PrefixStore.crossOverBottles(root: bottlesDir, steamApps: steamAppsDir)
        #expect(bottles.first?.installedApps.first?.isLinked == false)
    }

    @Test("Linking cleanly replaces small stub directory with bottle symlink")
    func replacesPlaceholderDirectoryWhenLinking() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottlesDir = root.appending(path: "Bottles")
        let bottle = bottlesDir.appending(path: "Steam")
        let steamAppsDir = root.appending(path: "steamapps")

        let manifestURL = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/appmanifest_730.acf")
        try write("\"name\"\t\t\"CS2\"\n\"installdir\"\t\t\"CSGO\"\n", to: manifestURL)

        let bottleGame = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common/CSGO")
        try write("game-bytes", to: bottleGame.appending(path: "cs2.exe"))

        // Create a 16KB placeholder directory in macOS Steam common
        let placeholder = steamAppsDir.appending(path: "common/CSGO")
        try write("empty stub", to: placeholder.appending(path: "installscript.vdf"))

        let app = BottleApp(
            appID: "730",
            name: "CS2",
            installdir: "CSGO",
            manifestURL: manifestURL,
            isLinked: false
        )
        let b = CrossOverBottle(
            name: "Steam",
            url: bottle,
            hasWindowsSteam: true,
            isPreview: false,
            installedApps: [app]
        )

        try PrefixStore.linkBottleApp(app, from: b, steamApps: steamAppsDir)

        let dstGame = steamAppsDir.appending(path: "common/CSGO")
        let isLink = (try? dstGame.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
        #expect(isLink == true)
        #expect(FileManager.default.fileExists(atPath: dstGame.appending(path: "cs2.exe").path(percentEncoded: false)))
    }
}
