import Testing

@testable import Overlay

struct OverlayPreviewTests {
    @Test
    func testPreviewReplacesACompletedSessionAndClearsItsMeter() async {
        await MainActor.run {
            let model = OverlayModel()
            model.content = .settled("Inserted", .ok)
            model.push(level: 0.8)

            model.preparePreview()

            #expect(model.content == .preview)
            #expect(model.levels.allSatisfy { $0 == 0 })
        }
    }

    @Test
    func testPreviewDoesNotInterruptListeningOrProcessing() async {
        await MainActor.run {
            for content in [OverlayContent.listening(partial: "Hello"), .working("Polishing…")] {
                let model = OverlayModel()
                model.content = content
                model.push(level: 0.8)
                let levels = model.levels

                model.preparePreview()

                #expect(model.content == content)
                #expect(model.levels == levels)
            }
        }
    }
}
