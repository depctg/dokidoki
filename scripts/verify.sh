#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/MangaCore
for destination in "platform=macOS,arch=$(uname -m)" 'generic/platform=iOS Simulator' 'generic/platform=visionOS Simulator'; do
    xcodebuild -quiet -project MangaViewer.xcodeproj -scheme MangaViewer \
        -destination "$destination" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
done
