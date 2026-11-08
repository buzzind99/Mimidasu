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

        #expect(Set(ASRModelChoice.allCases.map(\.displayName)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.modelName)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.approximateSize)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.blurb)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.ggufFileName)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.modelID)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.downloadURL)).count == ASRModelChoice.allCases.count)
        #expect(Set(ASRModelChoice.allCases.map(\.pinnedSHA256)).count == ASRModelChoice.allCases.count)
    }

    @Test("modelName exposes the underlying speech-model name")
    func modelNamePerChoice() {
        #expect(ASRModelChoice.lite.modelName == "SenseVoice-Small")
        #expect(ASRModelChoice.haas.modelName == "Haas-ja-v1.0")
        #expect(ASRModelChoice.full.modelName == "FunASR-Nano-2512")
    }

    @Test("the three choices read as Lite, Balanced and Full in order")
    func displayNamesAndOrder() {
        #expect(ASRModelChoice.lite.displayName == "Lite")
        #expect(ASRModelChoice.haas.displayName == "Balanced")
        #expect(ASRModelChoice.full.displayName == "Full")
        #expect(ASRModelChoice.allCases == [.lite, .haas, .full])
    }

    @Test("Haas pins the q8_0 download exactly")
    func haasDownloadPin() {
        #expect(ASRModelChoice.haas.ggufFileName == "haas-ja-v1.0-q8_0.gguf")
        #expect(ASRModelChoice.haas.modelID == "Haas-ja-v1.0-GGUF")
        #expect(ASRModelChoice.haas.revision == "607fa1450398d589643fbb0e8bb1d0424af68d11")
        #expect(
            ASRModelChoice.haas.downloadURL.absoluteString
                == "https://huggingface.co/cstr/Haas-ja-v1.0-GGUF/resolve/"
                + "607fa1450398d589643fbb0e8bb1d0424af68d11/haas-ja-v1.0-q8_0.gguf"
        )
        #expect(
            ASRModelChoice.haas.pinnedSHA256
                == "630fb47ac99d5111b0f99a7488857405611f05d7acae0fb2ceba4847ae1f9a2c"
        )
        #expect(ASRModelChoice.haas.approximateSize == "~650 MB")
    }

    @Test("raw values stay stable for persisted selections")
    func rawValuesAreStable() {
        #expect(ASRModelChoice(rawValue: "lite") == .lite)
        #expect(ASRModelChoice(rawValue: "haas") == .haas)
        #expect(ASRModelChoice(rawValue: "full") == .full)
    }
}
