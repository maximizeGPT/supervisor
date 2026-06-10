# Supervisor landing page

One-page waitlist site for Supervisor, the native macOS app that supervises
Claude Code sessions. Next.js (App Router) + Tailwind, deploys to Vercel with
zero config.

## Develop

```bash
npm run dev      # http://localhost:3000
npm run build    # production build (also what Vercel runs)
npm run start    # serve the production build locally
```

## Wire up the waitlist (no backend)

The form POSTs to a single pluggable endpoint. Set it once:

```bash
cp .env.example .env.local
# then edit .env.local:
NEXT_PUBLIC_WAITLIST_ENDPOINT=https://formspree.io/f/your-id
```

Any endpoint that accepts a POST works (Formspree, Buttondown, your own URL).
Until it is set, the form validates the email and shows the success state
locally without sending or storing anything. The endpoint logic lives in
[`components/WaitlistForm.tsx`](components/WaitlistForm.tsx).

## The parked download button

The "Download for macOS / Available soon" button is intentionally inert. The
signed build does not exist yet. When the `.dmg` is ready, swap the `<button>`
for a real link in [`components/Landing.tsx`](components/Landing.tsx) (search
for `ParkedDownload`).

## Deploy to Vercel

1. Push this repo to GitHub.
2. Import it in Vercel (framework auto-detects as Next.js, no settings needed).
3. Add the `NEXT_PUBLIC_WAITLIST_ENDPOINT` environment variable.
4. Before launch, set `metadataBase` in [`app/layout.tsx`](app/layout.tsx) to the
   production domain so the social-card / OpenGraph image resolves.

## Brand

Tokens (Signal green, Ink, Paper, Mute) live in
[`app/globals.css`](app/globals.css); the source brand assets are in
[`public/branding/`](public/branding/). Fonts: Inter + JetBrains Mono via
`next/font`.
