import Foundation
@testable import Mimidasu
import Testing

@Suite("ASRModelChoice")
struct ASRModelChoiceTests {
    @Test("every choice exposes complete display and download metadata")
    func metadataPerChoice() {
        for choice in ASRModelChoice.allCases {
            #expect(choice.id == choice.rawValue)
            #expect(!choice.displayName.isEmpty)
            #expect(!choice.modelName.isEmpty)
            #expect(!choice.approximateSize.isEmpty)
            #expect(!choice.blurb.isEmpty)
            #expect(choice.pinnedSHA256.count == 64)
            #expect(
                choice.pinnedSHA256.allSatisfy { char in
                    char.isHexDigit && !char.isUppercase
                }
            )
            #expect(choice.downloadURL.lastPathComponent == choice.ggufFileName)
            #expect(choice.downloadURL.path.contains(choice.modelID))
        }

        #expect(ASRModelChoice.lite.displayName == "Lite")
        #expect(ASRModelChoice.full.displayName == "Full")
        #expect(ASRModelChoice.lite.modelName != ASRModelChoice.full.modelName)
        #expect(ASRModelChoice.lite.approximateSize != ASRModelChoice.full.approximateSize)
        #expect(ASRModelChoice.lite.blurb != ASRModelChoice.full.blurb)
        #expect(ASRModelChoice.lite.ggufFileName != ASRModelChoice.full.ggufFileName)
        #expect(ASRModelChoice.lite.modelID != ASRModelChoice.full.modelID)
        #expect(ASRModelChoice.lite.downloadURL != ASRModelChoice.full.downloadURL)
        #expect(ASRModelChoice.lite.pinnedSHA256 != ASRModelChoice.full.pinnedSHA256)
    }

    @Test("modelName exposes the underlying speech-model name")
    func modelNamePerChoice() {
        #expect(ASRModelChoice.lite.modelName == "SenseVoice-Small")
        #expect(ASRModelChoice.full.modelName == "FunASR-Nano-2512")
    }

    @Test("allCases enumerates exactly Lite and Full in order")
    func allCasesAreLiteAndFull() {
        #expect(ASRModelChoice.allCases == [.lite, .full])
    }
}
