import type { APIRoute } from "astro"

import { siteConfig, withBasePath } from "../../site.config.mjs"

export const prerender = true

export const GET: APIRoute = () => {
  const manifest = {
    name: siteConfig.appName,
    short_name: siteConfig.name,
    description: siteConfig.description,
    start_url: withBasePath(),
    display: "browser",
    background_color: "#f5f7fb",
    theme_color: "#f5f7fb",
    icons: [
      {
        src: withBasePath("icons/icon-192.png"),
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: withBasePath("icons/icon-512.png"),
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
    ],
  }

  return new Response(JSON.stringify(manifest), {
    headers: {
      "Content-Type": "application/manifest+json; charset=utf-8",
    },
  })
}
