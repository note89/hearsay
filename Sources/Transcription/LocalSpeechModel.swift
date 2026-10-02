import Foundation

/// A downloadable speech model whose inference runs entirely on this Mac.
public enum LocalSpeechModel: String, CaseIterable, Equatable, Sendable {
    case cohere
    case qwen
    case redux
    case whisper

    public var label: String {
        switch self {
        case .cohere: return "Cohere Transcribe 2B"
        case .qwen: return "Qwen3-ASR 1.7B"
        case .redux: return "Parakeet Redux"
        case .whisper: return "Whisper large-v3-turbo"
        }
    }

    public var detail: String {
        switch self {
        case .cohere: return "14 languages · choose a language · 8-bit · 2.4 GB"
        case .qwen: return "30 languages · automatic language detection · 2.5 GB"
        case .redux: return "25 European languages · automatic language detection · 220 MB"
        case .whisper: return "100 languages · choose a language · 1.6 GB"
        }
    }

    public var wireKey: String {
        switch self {
        case .cohere: return "cohere/transcribe-03-2026"
        case .qwen: return "qwen/qwen3-asr-1.7b"
        case .redux: return "moondream/parakeet-redux"
        case .whisper: return "whisper/large-v3-turbo"
        }
    }

    public var repositoryID: String { package.repositoryID }
    public var revision: String { package.revision }
    public var downloadBytes: Int64 { package.artifacts.reduce(0) { $0 + $1.byteCount } }
    public var needsLocale: Bool {
        switch self {
        case .cohere, .whisper: return true
        case .qwen, .redux: return false
        }
    }

    /// Languages that can be selected explicitly. Automatic engines identify the language themselves.
    public var languageCodes: [String] {
        needsLocale ? supportedLanguageCodes : []
    }

    public var supportedLanguageCodes: [String] {
        switch self {
        case .cohere: return ["en", "fr", "de", "it", "es", "pt", "el", "nl", "pl", "zh", "ja", "ko", "vi", "ar"]
        case .qwen:
            return [
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja", "tr",
                "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
            ]
        case .redux:
            return [
                "en", "de", "fr", "es", "it", "pt", "ru", "uk", "hr", "sl", "lv", "lt", "et", "fi", "sv", "da",
                "nl", "pl", "cs", "sk", "hu", "ro", "bg", "el", "mt",
            ]
        case .whisper:
            return [
                "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de",
                "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht",
                "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt",
                "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa",
                "pl", "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw",
                "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
            ]
        }
    }

    public func languageCode(for locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        return languageCodes.first {
            Locale(identifier: $0).language.languageCode?.identifier == code
        }
    }

    var package: LocalModelPackage {
        switch self {
        case .cohere:
            return LocalModelPackage(
                repositoryID: "beshkenadze/cohere-transcribe-03-2026-mlx-8bit",
                revision: "d1f843476f84846e6fe7aa58a6033f17882f0ec9",
                artifacts: [
                    LocalModelArtifact(
                        relativePath: "README.md", byteCount: 1804, digest: .gitBlobSHA1("c32769b940c54d4c80e076ff97237d24b3ae32dd")),
                    LocalModelArtifact(
                        relativePath: "config.json", byteCount: 4336, digest: .gitBlobSHA1("a8d13de3ecca82362c0756a92fc181e8cdbac5a0")),
                    LocalModelArtifact(
                        relativePath: "model.safetensors", byteCount: 2_418_031_831,
                        digest: .sha256("bd1edbe982f47d22e64ba5723a4204b43ca93ea703b18946160d44ec26c83ab9")),
                    LocalModelArtifact(
                        relativePath: "preprocessor_config.json", byteCount: 420,
                        digest: .gitBlobSHA1("4f261dcb01c6cf62f7bb12a8debc54495d9a0dc6")),
                    LocalModelArtifact(
                        relativePath: "special_tokens_map.json", byteCount: 4091,
                        digest: .gitBlobSHA1("2554feeb7e14e1ce26fc28afc358df1ac7e67727")),
                    LocalModelArtifact(
                        relativePath: "tokenizer.model", byteCount: 492827,
                        digest: .sha256("6d21e6a83b2d0d3e1241a7817e4bef8eb63bcb7cfe4a2675af9a35ff3bbf0e14")),
                    LocalModelArtifact(
                        relativePath: "tokenizer_config.json", byteCount: 48141,
                        digest: .gitBlobSHA1("51aad8a4f2c2baf7bb8040f189006de9c2dac462")),
                ]
            )
        case .qwen:
            return LocalModelPackage(
                repositoryID: "mlx-community/Qwen3-ASR-1.7B-8bit",
                revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
                artifacts: [
                    LocalModelArtifact(
                        relativePath: "README.md", byteCount: 1008, digest: .gitBlobSHA1("b835cd3f6d4f5a2dd6b7f3ad83138166bdf5f1b5")),
                    LocalModelArtifact(
                        relativePath: "chat_template.json", byteCount: 1161,
                        digest: .gitBlobSHA1("c44736493efd71ec96218cc626904698cdb13235")),
                    LocalModelArtifact(
                        relativePath: "config.json", byteCount: 7188, digest: .gitBlobSHA1("888cc7fae19ea9ede543b1ae82e9c78aa06104ca")),
                    LocalModelArtifact(
                        relativePath: "generation_config.json", byteCount: 142,
                        digest: .gitBlobSHA1("7382a4d347c0a865b76bb1b8277f66a5ac312854")),
                    LocalModelArtifact(
                        relativePath: "merges.txt", byteCount: 1_671_853, digest: .gitBlobSHA1("31349551d90c7606f325fe0f11bbb8bd5fa0d7c7")),
                    LocalModelArtifact(
                        relativePath: "model.safetensors", byteCount: 2_463_307_541,
                        digest: .sha256("bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c")),
                    LocalModelArtifact(
                        relativePath: "model.safetensors.index.json", byteCount: 78968,
                        digest: .gitBlobSHA1("f0191caac2794d5b6fba0ab3eeb70f8eff90319e")),
                    LocalModelArtifact(
                        relativePath: "preprocessor_config.json", byteCount: 330,
                        digest: .gitBlobSHA1("8f7f07346466d5d494ec0d4969d1c3d0190eed72")),
                    LocalModelArtifact(
                        relativePath: "tokenizer_config.json", byteCount: 12487,
                        digest: .gitBlobSHA1("b93109843922a40c6654c5449d3bf95372267c66")),
                    LocalModelArtifact(
                        relativePath: "vocab.json", byteCount: 2_776_833, digest: .gitBlobSHA1("4783fe10ac3adce15ac8f358ef5462739852c569")),
                ]
            )
        case .redux:
            return LocalModelPackage(
                repositoryID: "FluidInference/parakeet-redux-coreml",
                revision: "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9",
                artifacts: [
                    LocalModelArtifact(
                        relativePath: "Decoder.mlmodelc/analytics/coremldata.bin", byteCount: 243,
                        digest: .sha256("7f24e7248d57024c6f1c5a2ea306f4a6a89db45a363218523bb6410c4b1aecf0")),
                    LocalModelArtifact(
                        relativePath: "Decoder.mlmodelc/coremldata.bin", byteCount: 560,
                        digest: .sha256("422da51d983e93a3e48cd6d46a17d6c32844452414c8e242fb0caaca2b8af5ed")),
                    LocalModelArtifact(
                        relativePath: "Decoder.mlmodelc/model.mil", byteCount: 13110,
                        digest: .gitBlobSHA1("36dcd5cbb71d13f42a177427ddbab7539e0d167e")),
                    LocalModelArtifact(
                        relativePath: "Decoder.mlmodelc/weights/weight.bin", byteCount: 23_604_992,
                        digest: .sha256("6c6c88c23ee5492a6b229e8cc636ddadb2b01ae0dd559d9cb63123bebf507d77")),
                    LocalModelArtifact(
                        relativePath: "Encoder.mlmodelc/analytics/coremldata.bin", byteCount: 243,
                        digest: .sha256("7862e972e09315df099d4bfd320743bf106acbf7fe4343317f9de45b0635d7b7")),
                    LocalModelArtifact(
                        relativePath: "Encoder.mlmodelc/coremldata.bin", byteCount: 506,
                        digest: .sha256("ca0b212fe3c06c3ccd35e508fa61e4dfaad19dd0c55b82e4f5bf8711e7758fd9")),
                    LocalModelArtifact(
                        relativePath: "Encoder.mlmodelc/model.mil", byteCount: 965906,
                        digest: .gitBlobSHA1("8328897b1fce282401724875571b75b6c542c4ed")),
                    LocalModelArtifact(
                        relativePath: "Encoder.mlmodelc/weights/weight.bin", byteCount: 182_389_312,
                        digest: .sha256("adbb5550dc6488717d3a1407b53122fbdb1af5e99c330ee20f8d8cfd9ec49252")),
                    LocalModelArtifact(
                        relativePath: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", byteCount: 243,
                        digest: .sha256("fc857a756b8c9c9f31aa9e1062766cc0a82ac035ef369d6e1cbe97184921479c")),
                    LocalModelArtifact(
                        relativePath: "JointDecisionv3.mlmodelc/coremldata.bin", byteCount: 592,
                        digest: .sha256("611ea653e2adede7cc1cfe70da36296844f97e95e2c7dd961d45230e5599389d")),
                    LocalModelArtifact(
                        relativePath: "JointDecisionv3.mlmodelc/model.mil", byteCount: 11777,
                        digest: .gitBlobSHA1("be552d46f98f9dc9b242b0d1659833db60aa3f83")),
                    LocalModelArtifact(
                        relativePath: "JointDecisionv3.mlmodelc/weights/weight.bin", byteCount: 12_642_764,
                        digest: .sha256("73b0288acd115fc4c36038f66b6cbf49233182488febf5d8c787bea4009535f7")),
                    LocalModelArtifact(
                        relativePath: "Preprocessor.mlmodelc/analytics/coremldata.bin", byteCount: 243,
                        digest: .sha256("c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d")),
                    LocalModelArtifact(
                        relativePath: "Preprocessor.mlmodelc/coremldata.bin", byteCount: 486,
                        digest: .sha256("dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d")),
                    LocalModelArtifact(
                        relativePath: "Preprocessor.mlmodelc/metadata.json", byteCount: 2841,
                        digest: .gitBlobSHA1("06162c58cf2f5343a0e60f36f843bcdf3cc58527")),
                    LocalModelArtifact(
                        relativePath: "Preprocessor.mlmodelc/model.mil", byteCount: 28181,
                        digest: .gitBlobSHA1("f987e2479228436c49189aa47edb376db74dcff5")),
                    LocalModelArtifact(
                        relativePath: "Preprocessor.mlmodelc/weights/weight.bin", byteCount: 491072,
                        digest: .sha256("129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea")),
                    LocalModelArtifact(
                        relativePath: "README.md", byteCount: 4972, digest: .gitBlobSHA1("9f4866223bf4bdc19b9260aaf0b6a93ebe6d88ee")),
                    LocalModelArtifact(
                        relativePath: "config.json", byteCount: 458, digest: .gitBlobSHA1("1cc7d67913a2beddfaae005094a25171d0a3f18b")),
                    LocalModelArtifact(
                        relativePath: "parakeet_v3_vocab.json", byteCount: 151122,
                        digest: .gitBlobSHA1("c684822ec3b671ebc449c433a7012398d39b8bb0")),
                    LocalModelArtifact(
                        relativePath: "parakeet_vocab.json", byteCount: 151122,
                        digest: .gitBlobSHA1("c684822ec3b671ebc449c433a7012398d39b8bb0")),
                ]
            )
        case .whisper:
            return LocalModelPackage(
                repositoryID: "openai/whisper-large-v3-turbo",
                revision: "41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
                artifacts: [
                    LocalModelArtifact(
                        relativePath: "README.md", byteCount: 21196, digest: .gitBlobSHA1("0bbe30273338d7e19f779c1343808e32617e64d1")),
                    LocalModelArtifact(
                        relativePath: "added_tokens.json", byteCount: 34648,
                        digest: .gitBlobSHA1("1b33526d33aaa60d79f78ae8651dae50b730185a")),
                    LocalModelArtifact(
                        relativePath: "config.json", byteCount: 1256, digest: .gitBlobSHA1("ad2f44ff1ed66e12765b2392dc041469db91a462")),
                    LocalModelArtifact(
                        relativePath: "generation_config.json", byteCount: 3772,
                        digest: .gitBlobSHA1("cbe752958dc3e4671b0e0220aa1c545423a6d5f5")),
                    LocalModelArtifact(
                        relativePath: "merges.txt", byteCount: 493869, digest: .gitBlobSHA1("6038932a2a1f09a66991b1c2adae0d14066fa29e")),
                    LocalModelArtifact(
                        relativePath: "model.safetensors", byteCount: 1_617_824_864,
                        digest: .sha256("542566a422ae4f3fd23f1ba11add198fca01bbf82e66e6a2857b3f608b1eb9d1")),
                    LocalModelArtifact(
                        relativePath: "normalizer.json", byteCount: 52666, digest: .gitBlobSHA1("dd6ae819ad738ac1a546e9f9282ef325c33b9ea0")),
                    LocalModelArtifact(
                        relativePath: "preprocessor_config.json", byteCount: 340,
                        digest: .gitBlobSHA1("931c77a740890c46365c7ae0c9d350ba3cca908f")),
                    LocalModelArtifact(
                        relativePath: "special_tokens_map.json", byteCount: 2186,
                        digest: .gitBlobSHA1("312bc106291bb51bf2cc1648df070bef963a0639")),
                    LocalModelArtifact(
                        relativePath: "tokenizer.json", byteCount: 2_710_337,
                        digest: .gitBlobSHA1("17456db595adc78a973f97d69d8cb50bc87c0b1c")),
                    LocalModelArtifact(
                        relativePath: "tokenizer_config.json", byteCount: 282843,
                        digest: .gitBlobSHA1("06ffdc8308eae6bb7bd1fdd81e94b0a881a539ab")),
                    LocalModelArtifact(
                        relativePath: "vocab.json", byteCount: 1_036_558, digest: .gitBlobSHA1("0f3456460629e21d559c6daa23ab6ce3644e8271")),
                ]
            )
        }
    }
}

struct LocalModelPackage: Equatable, Sendable {
    let repositoryID: String
    let revision: String
    let artifacts: [LocalModelArtifact]

    var downloadBytes: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }

    func downloadURL(for artifact: LocalModelArtifact) -> URL {
        URL(string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(artifact.relativePath)")!
    }
}

struct LocalModelArtifact: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let digest: LocalModelDigest
}

enum LocalModelDigest: Codable, Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String)
}
