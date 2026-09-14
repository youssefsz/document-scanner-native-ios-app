# DocScanner landing page

This directory contains the public website for DocScanner: PDF Scan. It is a
static Astro site built from the VeloCare landing-page source, with DocScanner
branding, product captures, copy, legal routes, and SEO metadata.

## Local development

```sh
pnpm install
pnpm dev
```

The `.env` file sets the public URL used by production builds:

```sh
PUBLIC_SITE_URL=https://youssef.tn/DocScanner/
```

Change this value to a root domain or another folder when the deployment location
changes. The build prefixes every internal route and asset with this path and
uses the complete URL for canonical links, sitemap entries, and social metadata.

## Checks

```sh
pnpm format
pnpm lint
pnpm typecheck
pnpm build
pnpm seo:check
```

The build regenerates browser icons and the social image from the checked-in
DocScanner artwork. Astro writes the production site to `dist/`. Upload the
contents of `dist/` to the location set by `PUBLIC_SITE_URL`.

## Page structure

- `src/pages/index.astro` composes the homepage and its scroll behavior.
- `src/pages/privacy.astro` and `src/pages/support.astro` keep the existing public routes.
- `src/pages/403.astro` and `src/pages/404.astro` provide the branded error pages. The build also emits `403.html` for web-host error mapping.
- `src/components/` contains the copied header, hero, phone frame, feature section, FAQ, download section, drawer, and footer.
- `src/styles/global.css` owns the DocScanner theme, responsive rules, motion, and accessibility fallbacks.
- `src/assets/screens/` contains the five real DocScanner captures used in the hero and feature section.
- `site.config.mjs` is the source for public URLs, app identity, and metadata.

The opening animation, app-name shimmer, scroll-aligned phone fan, animated FAQ,
mobile download drawer, and reduced-motion fallbacks match the copied reference
implementation.
