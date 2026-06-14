/* ── LaunchList referral waitlist (embed widget) ───────────────────────────
   Free tier. The LaunchList embed widget renders the signup form and the full
   viral flow (referral link, queue position, reward tiers, share) in one place.
   The loader script lives in app/layout.tsx; it turns each .launchlist-widget
   div into the hosted widget.

   The form key is public by design (LaunchList embeds it in its own client-side
   widget), so NEXT_PUBLIC_ is correct and there is no server secret or backend.
   Set NEXT_PUBLIC_LAUNCHLIST_KEY to your project's form key; without it the
   widget renders empty.

   Reward tiers, the share message, and the confirmation email are configured in
   the LaunchList dashboard (Referral and Emails), not in code.

   The `tone` prop is kept so both placements (hero dark, closing light) call the
   same component; widget appearance itself is set in the LaunchList dashboard.   */
const LAUNCHLIST_KEY = process.env.NEXT_PUBLIC_LAUNCHLIST_KEY ?? "";

export default function WaitlistForm({ tone = "light" }: { tone?: "light" | "dark" }) {
  return (
    <div data-tone={tone} className="w-full">
      <div className="launchlist-widget" data-key-id={LAUNCHLIST_KEY} />
    </div>
  );
}
