# DocScanner App Store assets

This folder contains the illustrated product page header and search results artwork for DocScanner 2.0.4. Use the capture guide below to rebuild the separate iPhone and iPad screenshot sets. Number those screenshots in display order and export each image as an opaque RGB PNG.

| Placement | Output path | Export size |
| --- | --- | --- |
| iPhone with Dynamic Island, medium display | `iphone/` for local screenshot exports | 1179 × 2556 px, portrait |
| iPad 13-inch display | `ipad/` for local screenshot exports | 2732 × 2048 px, landscape |
| Product page header | [`header/product-page-header.png`](header/product-page-header.png) | 3840 × 1646 px |
| Search results | [`search-results/search-results.png`](search-results/search-results.png) | 3840 × 2560 px |

Check Apple's current size requirements for each device slot before rebuilding the set. Apple accepts the iPad export size above in its 13-inch slot. [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) · [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)

## Capture the app

1. Run the `document-scaner` scheme from [`document-scaner.xcodeproj`](../../document-scaner.xcodeproj) on dedicated simulators. The original set used an iPhone 14 Pro in portrait and a third-generation 12.9-inch iPad Pro in landscape. Use light appearance, the default text size, and English for this set.
2. Create fictional invoice, brief, receipt, and agreement page images. Add the images to the simulator with `xcrun simctl addmedia <simulator-udid> <image-path> [...]`. In DocScanner, use **Import Photos** to build the PDFs, then organize them into Studio, Travel, Personal, and Receipts folders. Build a two-page `Studio Invoice` and add other titles containing `Invoice` for the search screenshot.
3. Capture the five screens below after transitions and previews settle. The original session used Python and Pillow to make the sample PDFs, a temporary capture build to load them, and XCUITest to navigate the real app. You can capture the same states from a normal simulator build with the commands below.

| File number | App state to capture |
| --- | --- |
| `01` | Library populated with an invoice, project brief, receipt, and agreement |
| `02` | `Studio Invoice` open on page 1 of 2, with the viewer controls visible |
| `03` | Folders tab showing the demo folders |
| `04` | Library filtered by `Invoice`, with the keyboard dismissed |
| `05` | **Share PDF** sheet showing the quality options and file size |

To capture manually, select the running simulator and set a consistent status bar. Set `capture_name` and run the last command once per screen after navigating to it.

```sh
xcrun simctl list devices booted
simulator_id='REPLACE_WITH_BOOTED_SIMULATOR_UDID'
capture_name='01-library'
mkdir -p captures
xcrun simctl ui "$simulator_id" appearance light
xcrun simctl status_bar "$simulator_id" override --time '9:41' \
	--dataNetwork wifi --wifiMode active --wifiBars 3 \
	--cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
xcrun simctl io "$simulator_id" screenshot "captures/$capture_name.png"
```

## Compose the artwork

Use one local HTML layout per screenshot export. Copy the frame markup from Yan Zhu's Devices.css demos and replace the `device-screen` image with the corresponding simulator PNG. The set uses the black iPhone 14 Pro frame with its Dynamic Island, sensors, and side buttons. For iPad, use the space gray iPad Pro frame. Rotate the frame into landscape and counter-rotate the screenshot inside it. Adjust the screen inset for the 12.9-inch capture and preserve the screenshot's aspect ratio. [iPhone frame](https://devicescss.xyz/phones.html#iphone-14-pro) · [iPad frame](https://devicescss.xyz/tablets.html#ipad-pro) · [Stylesheet version used](https://github.com/picturepan2/devices.css/blob/11846244977a4905a4fb9ac12bb2121e068d6147/dist/devices.min.css) · [Devices.css MIT license](https://github.com/picturepan2/devices.css/blob/11846244977a4905a4fb9ac12bb2121e068d6147/LICENSE)

Use the macOS system sans-serif and a short headline per image. The palette uses blue `#0765C7`, white `#FFFFFF`, cool white `#F5F7FB`, charcoal `#0B1324`, and accent blue `#086BCF`. The iPhone cards are blue with the copy above the device. The iPad cards are cool white with the headline on the left and the landscape iPad on the right. Keep the captured app screen large enough to read at store size.

Set the copy and device wrapper at these coordinates, in export pixels from the top-left corner. Apply scale with `transform-origin: 0 0`.

| Layout | Copy position | Device wrapper position | Frame scale |
| --- | --- | --- | --- |
| iPhone | x 118, y 102 | x 81, y 371 | 2.376× |
| iPad | x 132, vertically centered | x 695, y 262 | 2.52× |

For the iPad layout, the original CSS set the frame width to `597px` and the screen inset width to `543px`. The frame transform was `translateY(1504.44px) rotate(-90deg) scale(2.52)`. Inside the inset, a centered `720 × 539 px` screenshot rotated `90deg` to face the right way.

The screenshot references were Scanner Pro's scanner-focused messaging, PDF Expert's tablet presentation, and Things 3's typography and spacing. The interface and document imagery in the device screenshots came from the DocScanner simulators. [Scanner Pro](https://apps.apple.com/us/app/scanner-pro-scan-to-pdf/id333710667) · [PDF Expert](https://apps.apple.com/us/app/pdf-expert-editor-reader/id743974925) · [Things 3 for iPad](https://apps.apple.com/us/app/things-3-for-ipad/id904244226)

## Rebuild the illustrated creatives

The product page header and search card show a paper document becoming a PDF. The screenshot references from Document Scanner by Lufick informed the two formats. We made new illustrations in DocScanner's palette with Codex's built-in ImageGen. The header uses the wider side-by-side artwork so both pages fit in Apple's iPad landscape crop. The search card uses the compact artwork below the headline. Text and color are set in [`creative.css`](creative-source/creative.css).

Use [`product-page-header.html`](creative-source/layout/product-page-header.html) at `3840 × 1646` and [`search-results.html`](creative-source/layout/search-results.html) at `3840 × 2560`. These layouts load the original transparent artwork from [`creative-source/`](creative-source/), then export it on an opaque brand-blue background.

<details>
<summary>ImageGen prompts</summary>

**Search illustration**

> Generate ONE original isolated editorial product illustration on a real transparent background for DocScanner's App Store header and search artwork. The same illustration will be recomposed in two separate layouts with clean headline typography added later. Story at a glance: ordinary paper becomes a tidy searchable PDF. Show a compact pair of two overlapping objects, a narrow white paper receipt curling very slightly and leaning 8 degrees left in the foreground-left, and a larger perfectly straight crisp white digital PDF page behind/right, almost front-facing, with a folded electric-blue top-right corner. A small precise line of blue scanner light crosses the receipt and two or four compact blue right-angle crop brackets loosely hug its corners, a nod to the existing DocScanner icon. Both sheets contain dark charcoal document linework and a few blue rules, rendered as believable typeset invoice grids and lines without fake words, logos, or legible numbers. The only permitted characters on the art are a small, sharp white PDF on the blue folded corner, if useful. Favor modern editorial paper craft and real paper finish, sharp vector-like edges, quiet depth, minimal beveling, subtle soft shadows tight to the objects. White, charcoal #0B1324, rich scanner blue #0765C7 and lighter blue glints only. The illustration will sit on a solid brand-blue field, so keep paper highlights clean and shadows restrained. Strong visual hierarchy and recognizable document silhouettes at thumbnail scale. Compact subject slightly wider than it is tall, with each complete silhouette and generous transparent margins. No phone, no tablet, no hands, no human, no computer, no mock App Store UI, no teal, no gradients outside the objects, no background, no beams extending to the edge, no headline, no slogans, no extra props. The design is original, not a recreation of the teal reference.

**Header illustration**

Use `paper-to-pdf.png` from `creative-source/` as the reference image.

> Create an alternate wide horizontal composition of the supplied original DocScanner paper-to-PDF illustration for a shallow banner. Keep the same clean white receipt paper, charcoal typeset linework, blue scan beam and brackets, and clean white PDF with a folded blue PDF tab. Arrange the receipt on the left and PDF on the right as two distinct silhouettes, almost side by side with a very narrow deliberate gap, at comparable height and sharing a baseline. Make the receipt wider and shorter, like a printed invoice slip with a minimally curled paper edge, and lean it slightly left. The digital PDF on the right is a clean upright page, slightly wider than a conventional A4, with the original blue folded corner. Combined subject footprint (only the two papers from leftmost edge to rightmost edge) should be at least 1.75 times as wide as it is tall. The scene is a minimalist editorial product cutout with the same blue, graphite, and white brand colors, soft tight shadows, realistic paper, precise edges, and minimal visual noise. Preserve complete silhouettes and margins on transparent alpha. No extra arrows, no title, no devices, no background graphic. Only the literal PDF label may be readable. Keep glow limited to the thin cyan-blue scan stripe on the receipt.

</details>

## Render and check the exports

Render at the exact canvas size in headless Chromium. The set uses Microsoft Edge with a device scale factor of 1. Run this example from the `app-store-assets` directory and change the dimensions, filename, and layout path for each placement.

```sh
edge='/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
render_profile=$(mktemp -d)
"$edge" --headless=new --no-first-run --hide-scrollbars \
	--force-device-scale-factor=1 --window-size=3840,1646 \
	--user-data-dir="$render_profile" --screenshot="$PWD/product-page-header.png" \
	"file://$PWD/creative-source/layout/product-page-header.html"
```

- **Check dimensions and opacity.** Run `sips -g pixelWidth -g pixelHeight -g hasAlpha header/*.png search-results/*.png` from this folder. Run the same check on any local screenshot exports. Compare each result with the table above and check that `hasAlpha` is `no`.
- **Keep essential artwork inside the safe area.** For these export sizes, the header safe area starts at x 1097, y 493 and measures 1646 × 661 px. The search safe area starts at x 836, y 765 and measures 2168 × 1030 px. Extend the background to the canvas edges. [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)
- **Check the uploaded draft in Apple’s Device Preview.** Open **Header and Search Results**, then select **Preview**. The two-column header and stacked search card extend beyond the general safe areas. The iPhone previews showed the full headline and illustration in both placements. The iPad landscape preview also showed both papers in the header. Recheck these placements before reusing the layouts. [App Store Connect preview instructions](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets)
- **Check the content.** Screenshots must show the app in use. Disclose purchase requirements for paid features shown, and localize copy for each storefront language you support. Keep pricing, discount claims, external URLs, and unverified awards out of the creative. [App Review Guidelines, section 2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata) · [Apple's creative guidance](https://developer.apple.com/app-store/asset-best-practices/)

DocScanner artwork is covered by the repository's [visual asset policy](../../BRAND_ASSETS.md).
