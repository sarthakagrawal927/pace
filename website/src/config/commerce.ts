/**
 * Checkout URLs for the marketing site.
 *
 * Set `PUBLIC_PACE_CHECKOUT_URL` / `PUBLIC_STUDIO_CHECKOUT_URL` at
 * Cloudflare Pages build time when Stripe or Lemon Squeezy links exist.
 * Until then, the mailto fallback is the honest pre-launch purchase path.
 */
const paceMailtoCheckout =
  "mailto:hi@sarthakagrawal.dev?subject=Buy%20Pace%20(%2429)&body=Hi%20Sarthak%2C%20I%27d%20like%20to%20buy%20Pace%20for%20%2429.%20My%20Mac%20model%20is%3A%20";

const studioMailtoCheckout =
  "mailto:hi@sarthakagrawal.dev?subject=Pace%20Studio%20(%245%2Fmo)&body=Hi%20Sarthak%2C%20I%27d%20like%20Pace%20Studio.";

export const paceCheckoutURL =
  import.meta.env.PUBLIC_PACE_CHECKOUT_URL ?? paceMailtoCheckout;

export const studioCheckoutURL =
  import.meta.env.PUBLIC_STUDIO_CHECKOUT_URL ?? studioMailtoCheckout;

export const paceCheckoutIsMailto = paceCheckoutURL.startsWith("mailto:");
