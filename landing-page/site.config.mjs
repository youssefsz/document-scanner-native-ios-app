import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"

const envFile = fileURLToPath(new URL(".env", import.meta.url))
if (existsSync(envFile)) process.loadEnvFile(envFile)

const configuredSiteUrl = new URL(
  process.env.PUBLIC_SITE_URL?.trim() ||
    "http://localhost:4321/"
)

const normalizedPathname = configuredSiteUrl.pathname.replace(/^\/+|\/+$/g, "")
const basePath = normalizedPathname ? `/${normalizedPathname}` : "/"
const siteUrl = new URL(
  basePath === "/" ? "/" : `${basePath}/`,
  configuredSiteUrl.origin
)
export const withBasePath = (pathname = "") => {
  const relativePath = pathname.replace(/^\/+/, "")
  return basePath === "/" ? `/${relativePath}` : `${basePath}/${relativePath}`
}

export const siteUrlFor = (pathname = "") => {
  const normalizedPath = `/${pathname.replace(/^\/+/, "")}`
  const alreadyIncludesBase =
    basePath !== "/" &&
    (normalizedPath === basePath || normalizedPath.startsWith(`${basePath}/`))

  return new URL(
    alreadyIncludesBase ? normalizedPath : withBasePath(normalizedPath),
    configuredSiteUrl.origin
  )
}

export const siteConfig = Object.freeze({
  url: siteUrl.toString(),
  origin: configuredSiteUrl.origin,
  basePath,
  name: "DocScanner",
  appName: "DocScanner: PDF Scan",
  title: "DocScanner: PDF Scan | Private iPhone & iPad Scanner",
  description:
    "Scan paper and photos into searchable PDFs, organize files, and protect sensitive documents on your iPhone or iPad without an account or developer cloud.",
  heroHeadline: ["Scan every page.", "Keep it private."],
  locale: "en_US",
  language: "en",
  themeColor: "#f5f7fb",
  appStoreId: "6760237829",
  appStoreUrl:
    "https://apps.apple.com/app/id6760237829",
  privacyUrl: siteUrlFor("privacy/").toString(),
  supportUrl: siteUrlFor("support/").toString(),
  termsUrl: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/",
  githubUrl: "https://github.com/youssefsz/document-scanner-native-ios-app",
  supportEmail: "dhibi.ywsf@gmail.com",
  ogImagePath: "og/docscanner-og.png",
  ogImageAlt:
    "DocScanner app icon and document artwork with the message Scan every page. Keep it private.",
})
