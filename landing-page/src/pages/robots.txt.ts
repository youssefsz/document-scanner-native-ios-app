import type { APIRoute } from "astro"

import { siteConfig, withBasePath } from "../../site.config.mjs"

export const prerender = true

export const GET: APIRoute = () => {
  const sitemapUrl = new URL("sitemap-index.xml", siteConfig.url)

  return new Response(
    [
      "User-agent: *",
      `Allow: ${withBasePath()}`,
      "",
      `Sitemap: ${sitemapUrl.href}`,
      "",
    ].join("\n"),
    {
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
      },
    }
  )
}
