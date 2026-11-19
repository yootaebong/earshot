// swift-tools-version:5.9
// whisper.cpp 공식 릴리스의 xcframework(맥 슬라이스 arm64+x86_64 동적 프레임워크)를 그대로 쓴다.
import PackageDescription

let package = Package(
    name: "WhisperBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "whisper", targets: ["whisper"]),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
    ]
)
