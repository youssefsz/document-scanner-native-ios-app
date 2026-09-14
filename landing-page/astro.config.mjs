// @ts-check

import tailwindcss from "@tailwindcss/vite"
import { defineConfig } from "astro/config"
import react from "@astrojs/react"
import sitemap from "@astrojs/sitemap"

import { siteConfig } from "./site.config.mjs"

// https://astro.build/config
export default defineConfig({
  site: siteConfig.origin,
  base: siteConfig.basePath,
  trailingSlash: "ignore",
  vite: {
    plugins: [tailwindcss()],
  },
  integrations: [
    react(),
    sitemap({
      filter: (page) =>
        !page.endsWith("/403/") && !page.endsWith("/404/"),
    }),
  ],
})
