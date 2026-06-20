# Pace landing site

Static marketing surface for [pace.app](https://pace.app). Fleet web-stack standard: Astro 5 + Tailwind v4 + Lightning CSS, deployed to Cloudflare Pages.

## Setup

```bash
cd pace/website
npm install
npm run dev      # http://localhost:4321
npm run build    # → dist/
```

Single page at `/` composed of:

- `Nav` — single primary CTA, pricing link visible
- `Hero` — under-10-words headline, CSS-only animated demo above the fold
- `OnDevice` — the differentiation pitch ("nothing leaves your Mac")
- `Features` — six concrete capabilities, no weak words
- `Comparison` — table vs Wispr Flow / Raycast Pro / MacWhisper / Siri
- `Pricing` — Try / Pace ($29) / Studio ($5/mo)
- `SocialProof` — gated `showSocialProofSection = false` until real quotes exist
- `FAQ` — eight honest questions
- `Footer` — closing punchline ("0 bytes" daily counter) + signed founder paragraph

## OG image

`public/og-image.svg` is the current source. Convert to PNG before launch — most OG renderers prefer PNG. Quick conversion:

```bash
# requires rsvg-convert (brew install librsvg)
rsvg-convert -w 1200 -h 630 public/og-image.svg -o public/og-image.png
```

The `<head>` in `BaseLayout.astro` references `/og-image.png` — keep that path stable.

## Pre-launch audit

Walk [`fleet/LANDING_STANDARD.md`](../../LANDING_STANDARD.md) before going live.

Done in repo:

- [x] Founder signature in `Footer.astro`
- [x] OG PNG at `public/og-image.png` (regenerate: `bash ../scripts/generate-og-image.sh`)
- [x] Pricing CTA wired via `src/config/commerce.ts` (mailto fallback; set `PUBLIC_PACE_CHECKOUT_URL` at deploy for Stripe/Lemon)
- [x] Social proof uses private-beta themes — no fictional names (swap in attributed quotes when available)

Still manual:

- [ ] Replace private-beta theme cards with 3+ permissioned public quotes
- [ ] Set `PUBLIC_PACE_CHECKOUT_URL` to Stripe / Gumroad / Lemon Squeezy when live
- [ ] Confirm copy in `Comparison.astro` is current (competitor pricing rechecked within the month)

## Deploy

Cloudflare Pages with `pages_build_output_dir: dist`. Astro's static output is upload-ready.

```bash
npm run build
# upload dist/ to Cloudflare Pages, or:
# wrangler pages deploy dist --project-name pace
```
