# DocScanner landing design

## Product

DocScanner is a local-first document scanner for iPhone and iPad. The page uses
only shipped behavior and supplied captures. It does not invent ratings,
customers, download counts, cloud features, or security guarantees.

## Visual system

The copied VeloCare composition remains intact. DocScanner replaces its visual
language with cool paper white, dark ink, and iOS blue. Apple system typography
is preferred, with Inter as the bundled cross-platform fallback.

The app icon appears in the header, opening sequence, download drawer, closing
section, browser icons, and social image. Product screenshots remain unedited
inside the reusable phone frame.

## Layout and motion

The page order is header, hero, five-phone product fan, three-screen experience,
FAQ, closing App Store section, and footer. The opening icon holds at an enlarged
scale, then returns to its resting size while the rest of the hero appears. A
blue-white-blue shimmer crosses the app name continuously.

The hero phones begin at vertical offsets of `100 / 50 / 0 / 50 / 100` pixels.
Scrolling through the first 650 pixels brings them onto one baseline. The header
hides on downward scroll and returns on upward scroll. FAQ answers animate their
measured height in both directions. Compact screens use the existing Base UI
drawer for the download action.

Reduced Motion removes the intro, shimmer, scroll transforms, drawer transition,
and FAQ transition. The final layout remains usable without animation or
JavaScript.

## Content rules

- Describe OCR as offline and on-device.
- Describe secure folders as encrypted on the device and authorized by iOS.
- Describe DocScanner Pro as a one-time purchase, not a subscription.
- Do not imply that the developer operates document storage or user accounts.
- Use the live App Store listing and the official App Store badge for downloads.
