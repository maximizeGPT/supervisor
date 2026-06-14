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

Signups, referral tracking, and queue position are handled by LaunchList
(getlaunchlist.com, free tier). Create a project, then set its form key:

```bash
cp .env.example .env.local
# then edit .env.local:
NEXT_PUBLIC_LAUNCHLIST_KEY=your-form-key
```

The form key is public by design (LaunchList embeds it in its own client-side
widgets), so `NEXT_PUBLIC_` is correct and there is no server secret. The signup
posts directly to LaunchList's CORS-open JSON endpoint, so there is no backend or
route handler. Until the key is set, the waitlist runs in demo mode: it validates
the email and shows the full post-signup flow (referral link, queue position, and
share) locally, without sending anything anywhere. The flow lives in
[`components/WaitlistForm.tsx`](components/WaitlistForm.tsx).

Configure the confirmation email and the reward copy in the LaunchList dashboard.

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
