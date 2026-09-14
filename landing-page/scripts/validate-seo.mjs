import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"

import sharp from "sharp"

import { siteConfig, siteUrlFor, withBasePath } from "../site.config.mjs"

const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
)
const readDist = (file) =>
  readFile(path.join(projectRoot, "dist", file), "utf8")

const html = await readDist("index.html")
const forbiddenHtml = await readDist("403.html")
const forbiddenRouteHtml = await readDist(path.join("403", "index.html"))
const notFoundHtml = await readDist("404.html")
const privacyHtml = await readDist(path.join("privacy", "index.html"))
const supportHtml = await readDist(path.join("support", "index.html"))
const robots = await readDist("robots.txt")
const manifest = JSON.parse(await readDist("site.webmanifest"))
const sitemapIndex = await readDist("sitemap-index.xml")
const sitemap = await readDist("sitemap-0.xml")

const indexablePages = [
  { name: "homepage", html, url: siteConfig.url },
  { name: "privacy", html: privacyHtml, url: siteConfig.privacyUrl },
  { name: "support", html: supportHtml, url: siteConfig.supportUrl },
]
const errorPages = [
  { name: "403", html: forbiddenHtml },
  { name: "404", html: notFoundHtml },
]
const allPages = [...indexablePages, ...errorPages]

assert.equal(
  forbiddenHtml,
  forbiddenRouteHtml,
  "403 route and host error document must match"
)

const decodeHtml = (value) =>
  value
    .replaceAll("&amp;", "&")
    .replaceAll("&#39;", "'")
    .replaceAll("&quot;", '"')

const extract = (markup, pattern, message) => {
  const value = markup.match(pattern)?.[1]
  assert.ok(value, message)
  return value
}

const titles = new Set()
const descriptions = new Set()
const canonicals = new Set()

for (const page of indexablePages) {
  assert.match(page.html, /<html lang="en">/, `${page.name} language`)

  const encodedTitle = extract(
    page.html,
    /<title>([^<]+)<\/title>/,
    `${page.name} title`
  )
  const title = decodeHtml(encodedTitle)
  assert.ok(
    title.length >= 20 && title.length <= 65,
    `${page.name} title must contain 20 to 65 characters`
  )
  assert.ok(!titles.has(title), `${page.name} title must be unique`)
  titles.add(title)

  const description = decodeHtml(
    extract(
      page.html,
      /<meta name="description" content="([^"]+)"/,
      `${page.name} description`
    )
  )
  assert.ok(
    description.length >= 70 && description.length <= 170,
    `${page.name} description must contain 70 to 170 characters`
  )
  assert.ok(
    !descriptions.has(description),
    `${page.name} description must be unique`
  )
  descriptions.add(description)

  const canonical = extract(
    page.html,
    /<link rel="canonical" href="([^"]+)"/,
    `${page.name} canonical URL`
  )
  assert.equal(canonical, page.url, `${page.name} canonical URL`)
  assert.ok(!canonicals.has(canonical), `${page.name} canonical must be unique`)
  canonicals.add(canonical)

  assert.match(
    page.html,
    /<meta name="robots" content="index, follow,[^"]+">/,
    `${page.name} robots directive`
  )
  assert.equal(
    (page.html.match(/<h1(?:\s|>)/g) ?? []).length,
    1,
    `${page.name} must contain exactly one h1`
  )

  const headingLevels = [...page.html.matchAll(/<h([1-6])(?:\s|>)/g)].map(
    ([, level]) => Number(level)
  )
  assert.equal(headingLevels[0], 1, `${page.name} headings must begin with h1`)
  for (let index = 1; index < headingLevels.length; index += 1) {
    assert.ok(
      headingLevels[index] <= headingLevels[index - 1] + 1,
      `${page.name} heading hierarchy skips a level`
    )
  }

  assert.equal(
    decodeHtml(
      extract(
        page.html,
        /<meta property="og:title" content="([^"]+)"/,
        `${page.name} Open Graph title`
      )
    ),
    title,
    `${page.name} Open Graph title must match its page title`
  )
  assert.equal(
    decodeHtml(
      extract(
        page.html,
        /<meta property="og:description" content="([^"]+)"/,
        `${page.name} Open Graph description`
      )
    ),
    description,
    `${page.name} Open Graph description must match its meta description`
  )
  assert.equal(
    extract(
      page.html,
      /<meta property="og:url" content="([^"]+)"/,
      `${page.name} Open Graph URL`
    ),
    canonical,
    `${page.name} Open Graph URL must match its canonical URL`
  )
  assert.match(page.html, /<meta property="og:type" content="website">/)
  assert.match(page.html, /<meta property="og:image" content="https?:\/\//)
  assert.match(page.html, /<meta property="og:image:width" content="1200">/)
  assert.match(page.html, /<meta property="og:image:height" content="630">/)
  assert.match(page.html, /<meta property="og:image:alt" content="[^"]+">/)
  assert.match(
    page.html,
    /<meta name="twitter:card" content="summary_large_image">/
  )
  assert.match(page.html, /<meta name="twitter:title" content="[^"]+">/)
  assert.match(
    page.html,
    /<meta name="twitter:description" content="[^"]+">/
  )
  assert.match(page.html, /<meta name="twitter:image" content="https?:\/\//)
  assert.match(page.html, /<meta name="twitter:image:alt" content="[^"]+">/)

  const structuredData = JSON.parse(
    extract(
      page.html,
      /<script type="application\/ld\+json">([^<]+)<\/script>/,
      `${page.name} JSON-LD`
    )
  )
  const structuredTypes = structuredData["@graph"].map(
    (item) => item["@type"]
  )
  assert.ok(structuredTypes.includes("WebSite"))
  assert.ok(structuredTypes.includes("WebPage"))
  assert.ok(structuredTypes.includes("MobileApplication"))
}

for (const page of errorPages) {
  assert.equal(
    (page.html.match(/<h1(?:\s|>)/g) ?? []).length,
    1,
    `${page.name} must contain exactly one h1`
  )
  assert.match(
    page.html,
    /<meta name="robots" content="noindex, nofollow">/,
    `${page.name} noindex directive`
  )
  assert.ok(
    !page.html.includes('type="application/ld+json"'),
    `${page.name} must not publish structured data`
  )
}

for (const page of allPages) {
  for (const [anchor] of page.html.matchAll(/<a\b[^>]*>/g)) {
    const href = anchor.match(/\bhref="([^"]+)"/)?.[1]
    if (!href || !/^https?:\/\//.test(href)) continue

    const destination = new URL(decodeHtml(href))
    if (destination.origin === siteConfig.origin) continue

    assert.match(
      anchor,
      /\btarget="_blank"/,
      `${page.name} external link must open in a new tab: ${href}`
    )

    const rel = anchor.match(/\brel="([^"]+)"/)?.[1]?.split(/\s+/) ?? []
    assert.ok(
      rel.includes("noopener") && rel.includes("noreferrer"),
      `${page.name} external link must use noopener and noreferrer: ${href}`
    )
  }
}

const expectMarkup = (pattern, message) =>
  assert.match(html, pattern, `Missing or invalid ${message}`)

expectMarkup(/<html lang="en">/, "document language")
expectMarkup(/<title>[^<]{20,65}<\/title>/, "page title")
expectMarkup(/<meta name="description" content="[^\"]{70,170}"/, "description")
expectMarkup(
  new RegExp(
    `<link rel="canonical" href="${siteConfig.url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`
  ),
  "canonical URL"
)
expectMarkup(/<meta property="og:title" content="[^\"]+"/, "Open Graph title")
expectMarkup(
  /<meta property="og:description" content="[^\"]+"/,
  "Open Graph description"
)
expectMarkup(
  new RegExp(
    `<meta property="og:image" content="${siteUrlFor(siteConfig.ogImagePath).href.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`
  ),
  "absolute Open Graph image"
)
expectMarkup(
  /<meta property="og:image:width" content="1200"/,
  "Open Graph width"
)
expectMarkup(
  /<meta property="og:image:height" content="630"/,
  "Open Graph height"
)
expectMarkup(
  /<meta property="og:image:alt" content="[^\"]+"/,
  "Open Graph image alt"
)
expectMarkup(
  /<meta name="twitter:card" content="summary_large_image"/,
  "Twitter card"
)
expectMarkup(
  /<meta name="apple-itunes-app" content="app-id=6760237829"/,
  "Smart App Banner metadata"
)
expectMarkup(/<script type="application\/ld\+json">/, "JSON-LD")
expectMarkup(/"@type":"MobileApplication"/, "MobileApplication structured data")
expectMarkup(
  /"downloadUrl":"https:\/\/apps\.apple\.com\//,
  "App Store structured-data URL"
)
expectMarkup(
  new RegExp(
    `<link rel="manifest" href="${withBasePath("site.webmanifest").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`
  ),
  "web app manifest"
)

assert.equal(
  (html.match(/<h1(?:\s|>)/g) ?? []).length,
  1,
  "Expected exactly one h1"
)
assert.ok(
  !/coming soon/i.test(html),
  "Built page still contains outdated coming-soon copy"
)
assert.ok(!/VeloCare|bike maintenance|GPS ride/i.test(html), "Built page still contains VeloCare copy")
assert.match(
  privacyHtml,
  /This Privacy Policy explains what information/,
  "Privacy route is missing DocScanner content"
)
assert.match(supportHtml, /Help with DocScanner\./, "Support route is missing DocScanner content")
assert.match(forbiddenHtml, /<meta name="robots" content="noindex, nofollow">/)
assert.match(notFoundHtml, /<meta name="robots" content="noindex, nofollow">/)
assert.ok(
  (
    html.match(
      new RegExp(
        siteConfig.appStoreUrl.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
        "g"
      )
    ) ?? []
  ).length >= 5,
  "Expected every App Store action to use the live listing"
)
assert.ok(
  html.includes(`src="${withBasePath("download-black.svg")}"`),
  "Official App Store badge is missing"
)

for (const [, url] of html.matchAll(/\b(?:href|src)="(\/[^\"]*)"/g)) {
  assert.ok(
    siteConfig.basePath === "/" ||
      url === withBasePath() ||
      url.startsWith(`${siteConfig.basePath}/`),
    `Root-relative URL escapes the configured base path: ${url}`
  )
}

assert.ok(robots.includes(`Allow: ${withBasePath()}`))
assert.ok(robots.includes(`Sitemap: ${siteConfig.url}sitemap-index.xml`))
assert.ok(sitemapIndex.includes("sitemap-0.xml"))
assert.ok(sitemap.includes(`<loc>${siteConfig.url}</loc>`))
assert.ok(sitemap.includes(`<loc>${siteConfig.privacyUrl}</loc>`))
assert.ok(sitemap.includes(`<loc>${siteConfig.supportUrl}</loc>`))
assert.ok(!sitemap.includes("/403/"))
assert.ok(!sitemap.includes("/404/"))
assert.equal(manifest.start_url, withBasePath())
assert.deepEqual(
  manifest.icons.map(({ src, sizes }) => ({ src, sizes })),
  [
    { src: withBasePath("icons/icon-192.png"), sizes: "192x192" },
    { src: withBasePath("icons/icon-512.png"), sizes: "512x512" },
  ]
)

assert.ok(
  !html.includes("favicon.svg"),
  "Removed SVG favicon is still referenced"
)
for (const [file, size, rel] of [
  ["favicon.png", 48, "icon"],
  ["apple-touch-icon.png", 180, "apple-touch-icon"],
  ["icons/icon-192.png", 192],
  ["icons/icon-512.png", 512],
]) {
  const metadata = await sharp(path.join(projectRoot, "dist", file)).metadata()
  assert.equal(metadata.width, size, `${file} width`)
  assert.equal(metadata.height, size, `${file} height`)
  assert.equal(metadata.hasAlpha, false, `${file} must remain opaque`)
  if (rel) {
    const link = [...html.matchAll(/<link\b[^>]+>/g)]
      .map(([tag]) => tag)
      .find(
        (tag) =>
          tag.includes(`rel="${rel}"`) &&
          tag.includes(`href="${withBasePath(file)}"`)
      )
    assert.ok(
      link?.includes(`sizes="${size}x${size}"`),
      `${file} link and declared size`
    )
  }
}
const ico = await readFile(path.join(projectRoot, "dist/favicon.ico"))
assert.equal(ico.readUInt16LE(2), 1, "ICO type")
assert.equal(ico.readUInt16LE(4), 3, "ICO image count")
for (const [index, size] of [16, 32, 48].entries()) {
  const entry = 6 + index * 16
  const length = ico.readUInt32LE(entry + 8)
  const offset = ico.readUInt32LE(entry + 12)
  const metadata = await sharp(ico.subarray(offset, offset + length)).metadata()
  assert.equal(metadata.width, size, "ICO embedded width")
  assert.equal(metadata.height, size, "ICO embedded height")
}
assert.ok(html.includes(`href="${withBasePath("favicon.ico")}"`), "ICO link")
assert.ok(
  html.includes(`"logo":"${siteUrlFor("icons/icon-512.png").href}"`),
  "Structured-data logo"
)

const ogMetadata = await sharp(
  path.join(projectRoot, "dist", "og", "docscanner-og.png")
).metadata()
assert.equal(ogMetadata.width, 1200, "OG image width must be 1200")
assert.equal(ogMetadata.height, 630, "OG image height must be 630")
assert.equal(ogMetadata.format, "png", "OG image must be PNG")

console.log(
  "Search and social validation passed: metadata, heading structure, crawl controls, structured data, social cards, external-link behavior, icons, and social image."
)
