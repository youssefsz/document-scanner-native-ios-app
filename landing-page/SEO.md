# SEO contract

The `.env` file defines the complete public homepage used by production builds:

```sh
PUBLIC_SITE_URL=https://youssef.tn/DocScanner/
```

The value can point to a root domain or any hosted folder. The build uses its path
for every internal route and asset. It uses the complete URL for the sitemap,
canonical links, and social metadata.

`site.config.mjs` owns the app name, title, description, App Store ID, canonical
URL, theme color, and social-image details. `src/components/SEO.astro` emits the
canonical link, robots directives, Open Graph and Twitter fields, Smart App
Banner metadata, and `WebSite`, `WebPage`, and `MobileApplication` structured
data.

The structured data describes DocScanner as an iOS utility and links to App Store
ID `6760237829`. It does not contain ratings, reviews, prices, or download counts.

The production build creates `sitemap-index.xml`, a page sitemap, `robots.txt`,
the web app manifest, browser icons, and `og/docscanner-og.png`.

The public homepage, privacy policy, and support page are indexable. The 403 and
404 pages emit `noindex, nofollow` and are excluded from the sitemap. Unknown
routes return the custom 404 page whether or not the URL ends with a slash.
The build also writes `403.html` so a web host can use the same access-denied
design as its forbidden-response error document.

Build first, then run the SEO audit against the generated files:

```sh
pnpm build
pnpm seo:check
```

The check verifies metadata, canonical and base-path handling, the homepage,
privacy and support routes, App Store links, crawl files, icon dimensions, ICO
entries, and the 1200 by 630 social image.
