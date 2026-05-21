import Foundation
import Testing
@testable import TheBrowser

@MainActor
@Suite("Live-text composition across iterations")
struct ComposeLiveTextTests {
    @Test("Empty base + visible commentary yields just the trimmed commentary")
    func emptyBase() {
        let composed = ChatViewModel.composeLiveText(
            base: "",
            iterationVisible: "Looking up your inbox.\n\n"
        )
        #expect(composed == "Looking up your inbox.")
    }

    @Test("Empty iteration leaves base unchanged")
    func emptyIteration() {
        let composed = ChatViewModel.composeLiveText(
            base: "First, let me search.",
            iterationVisible: ""
        )
        #expect(composed == "First, let me search.")
    }

    @Test("Both non-empty get joined by a paragraph break")
    func paragraphJoin() {
        let composed = ChatViewModel.composeLiveText(
            base: "First, let me search.",
            iterationVisible: "Now opening that for you."
        )
        #expect(composed == "First, let me search.\n\nNow opening that for you.")
    }

    @Test("Trailing whitespace on the new piece is trimmed before joining")
    func trimmingPreservesBaseFormatting() {
        let composed = ChatViewModel.composeLiveText(
            base: "Earlier commentary.",
            iterationVisible: "Now opening.  \n  "
        )
        #expect(composed == "Earlier commentary.\n\nNow opening.")
    }

    @Test("Iteration containing only whitespace is treated as empty")
    func whitespaceOnlyIteration() {
        let composed = ChatViewModel.composeLiveText(
            base: "Prior text.",
            iterationVisible: "   \n\n  "
        )
        #expect(composed == "Prior text.")
    }
}
