// swift-tools-version: 5.9
// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import PackageDescription

// VENDORED from google-ai-edge/LiteRT-LM at the v0.14.0 tag commit
// (80f301ff9a3b02c2c1e7be2dd1a567752f7b51b6) — the last revision whose
// Swift sources match the shipped v0.14.0 binaries. Why not a remote SPM
// dependency: the tag's manifest carries stale checksums for the
// re-uploaded release artifacts (unresolvable), later revisions reference
// C symbols the binaries don't export (thinking config, constraint types),
// and the repo has a missing LFS object that aborts clones. Only changes
// here: the two checksums corrected to match the actual artifacts, test
// targets dropped. Re-check upstream when binaries newer than v0.14.0
// ship — that also unlocks ThinkingConfig for the LiteRT engine.

let package = Package(
  name: "LiteRTLM",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(
      name: "LiteRTLM",
      targets: ["LiteRTLM"]
    )
  ],
  targets: [
    // The Prebuilt Binary Target for iOS
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM.xcframework.zip",
      checksum: "dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1"
    ),
    // The Prebuilt Binary Target for Mac
    .binaryTarget(
      name: "CLiteRTLM_mac",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM_mac.xcframework.zip",
      checksum: "450615483509aaa6d34b321fdc6862e41a224b674468ab10aff64ebe113d21b7"
    ),
    // The Swift Wrapper Target
    .target(
      name: "LiteRTLM",
      dependencies: [
        .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
        .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS]))
      ],
      path: "swift",
      exclude: [
        "Info.plist"
      ],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-all_load"])
      ]
    ),
  ]
)
