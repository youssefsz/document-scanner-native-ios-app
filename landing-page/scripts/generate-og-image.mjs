import { fileURLToPath } from "node:url"
import path from "node:path"

import sharp from "sharp"
import { siteConfig } from "../site.config.mjs"

const escapeXml = (value) =>
  value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&apos;",
      })[character]
  )

const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
)
const documentPath = path.join(
  projectRoot,
  "src/assets/photography/document-hero.png"
)
const appIconPath = path.join(projectRoot, "src/assets/brand/app-icon.png")
const outputPath = path.join(projectRoot, "public/og/docscanner-og.png")

const width = 1200
const height = 630

const documentArt = await sharp(documentPath)
  .resize({
    width: 500,
    height: 500,
    fit: "contain",
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  })
  .png()
  .toBuffer()

const sourceIcon = await sharp(appIconPath)
  .resize(86, 86, { fit: "cover" })
  .png()
  .toBuffer()

const appIcon = await sharp(
  Buffer.from(`
  <svg width="86" height="86" viewBox="0 0 86 86" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <clipPath id="squircle">
        <path d="M43 0C19.5 0 10.2 0 5.1 5.1S0 19.5 0 43s0 32.8 5.1 37.9S19.5 86 43 86s32.8 0 37.9-5.1S86 66.5 86 43 86 10.2 80.9 5.1 66.5 0 43 0Z" />
      </clipPath>
    </defs>
    <g clip-path="url(#squircle)">
      <image width="86" height="86" href="data:image/png;base64,${sourceIcon.toString("base64")}" />
    </g>
    <path d="M43 1C20 1 11 1 5.9 5.9S1 20 1 43s0 32 4.9 37.1S20 85 43 85s32 0 37.1-4.9S85 66 85 43 85 11 80.1 5.9 66 1 43 1Z" fill="none" stroke="#fff" stroke-opacity="0.38" stroke-width="2" />
  </svg>
`)
)
  .png()
  .toBuffer()

const typography = Buffer.from(`
  <svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="canvas" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0%" stop-color="#f8fbff" />
        <stop offset="100%" stop-color="#e7f2ff" />
      </linearGradient>
      <radialGradient id="blueWash" cx="18%" cy="50%" r="62%">
        <stop offset="0%" stop-color="#70b9ff" stop-opacity="0.32" />
        <stop offset="100%" stop-color="#70b9ff" stop-opacity="0" />
      </radialGradient>
      <filter id="shadow" x="-60%" y="-60%" width="220%" height="220%">
        <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#194d88" flood-opacity="0.22" />
      </filter>
    </defs>

    <rect width="${width}" height="${height}" fill="url(#canvas)" />
    <rect width="${width}" height="${height}" fill="url(#blueWash)" />
    <rect x="28" y="28" width="1144" height="574" rx="28" fill="none" stroke="#0b1324" stroke-opacity="0.1" stroke-width="2" />
    <rect x="586" y="70" width="86" height="86" rx="21" fill="#fff" fill-opacity="0.01" filter="url(#shadow)" />

    <g font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', Inter, Arial, sans-serif">
      <text x="694" y="124" fill="#0b1324" font-size="24" font-weight="760" letter-spacing="-0.5">${escapeXml(siteConfig.appName)}</text>
      <text x="600" y="275" fill="#0b1324" font-size="69" font-weight="820" letter-spacing="-4.2">${escapeXml(siteConfig.heroHeadline[0])}</text>
      <text x="600" y="350" fill="#087cf0" font-size="69" font-weight="820" letter-spacing="-4.2">${escapeXml(siteConfig.heroHeadline[1])}</text>
      <text x="600" y="426" fill="#4f5d70" font-size="23" font-weight="470" letter-spacing="-0.35">Searchable PDFs, offline OCR, and secure folders.</text>
      <text x="600" y="461" fill="#4f5d70" font-size="23" font-weight="470" letter-spacing="-0.35">No account. No developer-operated document cloud.</text>
      <text x="600" y="548" fill="#086bd0" font-size="16" font-weight="760" letter-spacing="1.8">DOWNLOAD ON THE APP STORE</text>
    </g>
  </svg>
`)

await sharp(typography)
  .composite([
    { input: documentArt, left: 18, top: 76 },
    { input: appIcon, left: 586, top: 70 },
  ])
  .png({ compressionLevel: 9, palette: true, quality: 100 })
  .toFile(outputPath)

console.log(`Generated ${outputPath} (${width}x${height})`)
