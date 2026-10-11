import Testing
import OnDeviceUI
@testable import NativeUIReview

struct ClassifierLibraryTests {
    @Test func classifiersAreVisibleBeforeInstallationAndNotAssistantSelections() throws {
        let rows = CoreAIModelLibrary.catalog.filter { $0.category == .classifier }.map {
            CoreAIModelLibrary.entry(for: $0)
        }
        #expect(Set(rows.map(\.id)) == ["coreai:zoo-laya-multilingual", "coreai:zoo-julia-1"])
        #expect(rows.allSatisfy { $0.kind == .classifier && $0.isLibraryEntry && !$0.isInstalled && !$0.isSelectable })
        #expect(rows.allSatisfy { $0.declaredKinds == [.classifier] && !$0.supportedKinds.contains(.language) })
        let laya = try #require(rows.first { $0.id == "coreai:zoo-laya-multilingual" })
        let julia = try #require(rows.first { $0.id == "coreai:zoo-julia-1" })
        #expect(laya.availableCommands?.contains(.download) == true)
        #expect(julia.availableCommands == [.details])
        #expect(julia.unavailableReason?.contains("Mac") == true)
    }

    @Test func transfersPreserveIdentityAndCompletionMovesToInstalled() throws {
        let pack = try #require(CoreAIZooCatalog.model(id: "zoo-laya-multilingual"))
        let active = CoreAIModelLibrary.entry(for: pack, transfer: .downloading(0.4))
        #expect(active.downloadProgress == 0.4)
        #expect(active.availableCommands == [.details, .pauseDownload, .cancelDownload])
        let paused = CoreAIModelLibrary.entry(for: pack, transfer: .paused(0.4))
        #expect(paused.isDownloadPaused && paused.availableCommands?.contains(.download) == true)
        let installing = CoreAIModelLibrary.entry(for: pack, transfer: .installing)
        #expect(installing.availableCommands == [.details])
        let installed = CoreAIModelLibrary.entry(for: pack, isInstalled: true, transfer: .installing)
        #expect(installed.id == active.id && installed.isInstalled && installed.downloadStatus == nil)
        #expect(installed.availableCommands == [.details, .delete] && installed.isSelectable && installed.supportedKinds == [.classifier])
    }

    @Test func everyInstalledCoreAIPackCanBeDeletedIncludingUnavailablePacks() {
        for pack in CoreAIModelLibrary.catalog {
            let installed = CoreAIModelLibrary.entry(for: pack, isInstalled: true)
            #expect(installed.availableCommands?.contains(.delete) == true)
            #expect(installed.availableCommands?.contains(.download) == false)
            #expect(CoreAIModelLibrary.entry(for: pack).availableCommands?.contains(.delete) == false)
        }
    }
}
