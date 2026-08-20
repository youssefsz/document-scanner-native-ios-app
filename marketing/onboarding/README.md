# Onboarding screenshots

The app uses full-height portrait screenshots for the V1 comparison, V2 comparison, and Folders introduction.

Prepare these two full portrait screens in light appearance:

1. The V2 Library with fictional documents that match the V1 document set.
2. The V2 Folders screen with standard folders named `Receipts`, `Work`, and `School`.

Keep search inactive. Do not include a keyboard, alert, sheet, debug label, phone frame, campaign background, or personal document. Preserve the complete screenshot, including its status bar and bottom controls. The preparation script fits each complete image onto the same 852 by 1847 canvas without cropping, exports a quality-3 JPEG, writes the asset catalog files, and enforces a 250 KB per-image limit.

Run:

```sh
marketing/onboarding/prepare_onboarding_assets.sh \
  /path/to/v2-library.png \
  /path/to/v2-folders.png
```

Afterward, build the generic iOS device target and inspect all four screens on the supported device sizes before release.
