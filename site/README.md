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

## Wire up the waitlist (LaunchList)

Signups, referral tracking, queue position, reward tiers, and sharing are handled
by LaunchList (getlaunchlist.com, free tier) via its embed widget. Set the project
form key:

```bash
cp .env.example .env.local
# then edit .env.local:
NEXT_PUBLIC_LAUNCHLIST_KEY=your-form-key
```

The widget loader script lives in [`app/layout.tsx`](app/layout.tsx) and the embed
renders from [`components/WaitlistForm.tsx`](components/WaitlistForm.tsx) as
`<div class="launchlist-widget" data-key-id="...">`. The key is public by design
(LaunchList embeds it in its client-side widget), so `NEXT_PUBLIC_` is correct and
there is no server secret or backend. Without the key, the widget renders empty.

Reward tiers, the share message, and the confirmation email are configured in the
LaunchList dashboard (Referral and Emails), not in code.

## The parked download button

The "Download for macOS / Available soon" button is intentionally inert. The
signed build does not exist yet. When the `.dmg` is ready, swap the `<button>`
for a real link in [`components/Landing.tsx`](components/Landing.tsx) (search
for `ParkedDownload`).

## Deploy to Vercel

1. Push this repo to GitHub.
2. Import it in Vercel (framework auto-detects as Next.js, no settings needed).
3. Add the `NEXT_PUBLIC_LAUNCHLIST_KEY` environment variable.
4. Before launch, set `metadataBase` in [`app/layout.tsx`](app/layout.tsx) to the
   production domain so the social-card / OpenGraph image resolves.

## Brand

Tokens (Signal green, Ink, Paper, Mute) live in
[`app/globals.css`](app/globals.css); the source brand assets are in
[`public/branding/`](public/branding/). Fonts: Inter + JetBrains Mono via
`next/font`.
