# dokidoki" app icon

The app's display name includes the trailing quotation mark. The icon retains the reference's Japanese ドキドキ lettering and emphasis strokes, enlarged to 112%. The bundle identifier, target name and persistent data paths are independent of branding.

Open `App/AppIcon.icon` in Icon Composer. This native document is the source for iOS, iPadOS and macOS. It uses four vector groups, ordered **front to back** in `icon.json`: lettering, speech bubble, colored comic page, rear paper. The blue background is a native gradient, with a darker variant. Papers and stickers are opaque, with native shadows; translucency and specular highlights are disabled to keep the paper appearance. The system supplies masking, icon depth and clear/tinted renditions.

The user-supplied originals remain in `docs/icon-reference/`. Production SVGs correct their three-number viewBox to `0 0 1024 1024`; the original reference artwork is unchanged (only trailing whitespace was normalized). No concept PNG is used as the shipped icon. The Icon Composer file contains separate editable groups, not a flattened composite.

For a native rendered preview, use the executable bundled with Icon Composer (the separate `xcrun ictool` is the build compiler):

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  App/AppIcon.icon --export-image --output-file /tmp/dokidoki-preview.png \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
```

Also check `Dark` and `TintedDark`; the latter accepts `--tint-color` and `--tint-strength`. After a change, rebuild and inspect the icon from the built app as well as the Composer preview. A previously opened Composer window may still show an older document revision.

visionOS still requires an asset-catalog solid image stack, with at most three layers. Run `python3 scripts/export-vision-icon.py` after editing the source. The small authoring utility combines the two paper groups and the two foreground groups, preserves the letter transform, insets artwork for the circular mask, and rasterizes using Apple's `sips`. Only the generated PNG layers ship; the script and reference files are outside the app. No extra build step or runtime renderer is required. Xcode selects `AppIconVision` only for xrOS SDKs.

Apple references: [Icon Composer workflow and materials](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [visionOS layered asset catalogs](https://developer.apple.com/documentation/xcode/configuring-your-app-icon). The native document structure was checked against Apple's [Landmarks sample](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass).
