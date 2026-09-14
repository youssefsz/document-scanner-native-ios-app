# DocScanner website assets

`src/assets/brand/app-icon.png` is the 1024 by 1024 DocScanner app icon copied
from the native app asset catalog. The site uses it without changing the artwork.

`pnpm generate:brand` creates the header and footer mark, browser favicons, Apple
Touch icon, and manifest icons. `pnpm build` runs that generator before Astro
builds the site.

The five files in `src/assets/screens/` come from the previous DocScanner landing
page. They are 1179 by 2556 captures of the library, folders, document viewer,
PDF export options, and settings. The website presents them inside CSS phone
hardware without editing the captured interface.

The app icon, screenshots, and promotional artwork remain subject to the parent
repository's visual asset policy.
