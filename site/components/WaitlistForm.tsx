"use client";

import { useId, useState } from "react";

/* ── LaunchList referral waitlist ──────────────────────────────────────────
   Viral "skip the line" waitlist backed by LaunchList (getlaunchlist.com).

   >>> SET YOUR LAUNCHLIST FORM KEY <<<
   Create a free project at getlaunchlist.com, then set NEXT_PUBLIC_LAUNCHLIST_KEY
   in .env.local (and in Vercel), e.g.
       NEXT_PUBLIC_LAUNCHLIST_KEY=abc123
   The form key is public by design (LaunchList embeds it in its own client-side
   widgets), so NEXT_PUBLIC_ is correct and there is no server secret. LaunchList's
   submit endpoint is CORS-open and returns JSON, so the signup happens client side
   with no backend or route handler.

   Until a key is set, the flow runs in demo mode: it validates the email and shows
   the full post-signup screen (referral link, position, share) with a locally
   generated link, without sending anything anywhere.                            */
const LAUNCHLIST_KEY = process.env.NEXT_PUBLIC_LAUNCHLIST_KEY ?? "";
const IS_DEMO = LAUNCHLIST_KEY.trim() === "" || LAUNCHLIST_KEY.includes("PLACEHOLDER");

// Client-side email validation (one address, has an @ and a dotted domain).
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Reward ladder, shown after signup so people know why to refer.
const REWARDS: { tier: string; reward: string }[] = [
  { tier: "Join", reward: "you're on the list, see your spot" },
  { tier: "Refer 1", reward: "jump the line" },
  { tier: "Refer 3", reward: "first-wave download access when it ships" },
  {
    tier: "Refer 5",
    reward:
      "Founding User: free forever when paid tiers launch, private Discord, name in the credits",
  },
];

// Pre-filled X post (no em-dashes, stays well under 280 with the link appended).
const SHARE_LEAD =
  "I just joined the waitlist for Supervisor, a Mac app that supervises your Claude Code sessions so they keep shipping while you step away. Skip the line:";

type Status = "idle" | "submitting" | "success" | "error";
type Tone = "light" | "dark";
type Signup = { referralLink: string; position: number | null };

interface LaunchListResponse {
  ok?: boolean;
  error?: string;
  position?: number | string;
  priority?: number | string;
  rank?: number | string;
  place?: number | string;
  referral_link?: string;
  referralLink?: string;
  referral?: string;
  refer_url?: string;
  share_url?: string;
  link?: string;
  url?: string;
}

function buildXShareUrl(referralLink: string): string {
  return `https://x.com/intent/tweet?text=${encodeURIComponent(`${SHARE_LEAD} ${referralLink}`)}`;
}

// LaunchList's exact field names are not documented, so read tolerantly.
function parseSignup(data: LaunchListResponse, fallbackLink: string): Signup {
  const link =
    data.referral_link ||
    data.referralLink ||
    data.referral ||
    data.refer_url ||
    data.share_url ||
    data.link ||
    data.url ||
    fallbackLink;
  const raw = data.position ?? data.priority ?? data.rank ?? data.place;
  const num = typeof raw === "number" ? raw : raw != null ? Number(raw) : NaN;
  return { referralLink: link, position: Number.isFinite(num) ? num : null };
}

export default function WaitlistForm({ tone = "light" }: { tone?: Tone }) {
  const inputId = useId();
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>("idle");
  const [message, setMessage] = useState<string | null>(null);
  const [signup, setSignup] = useState<Signup | null>(null);

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = email.trim();

    if (!EMAIL_RE.test(value)) {
      setMessage("Enter a valid email address.");
      return;
    }
    setMessage(null);
    setStatus("submitting");

    const origin = typeof window !== "undefined" ? window.location.origin : "";

    // Demo mode: no key wired up yet, so show the full flow locally.
    if (IS_DEMO) {
      setSignup({ referralLink: `${origin}/?ref=demo`, position: 100 });
      setStatus("success");
      return;
    }

    try {
      // Carry any inbound referral code through: LaunchList reads it from the
      // query string (a referred visitor arrives at /?... and we forward it).
      const query = typeof window !== "undefined" ? window.location.search : "";
      const res = await fetch(`https://getlaunchlist.com/s/${LAUNCHLIST_KEY}${query}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "application/json",
        },
        body: new URLSearchParams({ email: value }).toString(),
      });
      const data = (await res.json().catch(() => ({}))) as LaunchListResponse;
      if (res.ok && data.ok !== false) {
        setSignup(parseSignup(data, `${origin}/?ref=`));
        setStatus("success");
      } else {
        setStatus("error");
        setMessage("Something went wrong. Please try again.");
      }
    } catch {
      setStatus("error");
      setMessage("Something went wrong. Please try again.");
    }
  }

  const dark = tone === "dark";
  const inputClass = dark
    ? "bg-white/5 border-white/15 text-paper placeholder:text-paper/40 focus:border-signal focus:ring-signal/40"
    : "bg-white border-paper-warm text-ink placeholder:text-mute focus:border-signal focus:ring-signal/30";
  const helpClass = dark ? "text-paper/60" : "text-ink/55";

  if (status === "success" && signup) {
    return <ReferralScreen tone={tone} signup={signup} />;
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="w-full">
      <div className="flex flex-col gap-3 sm:flex-row">
        <label htmlFor={inputId} className="sr-only">
          Email address
        </label>
        <input
          id={inputId}
          type="email"
          name="email"
          inputMode="email"
          autoComplete="email"
          placeholder="you@example.com"
          value={email}
          onChange={(event) => {
            setEmail(event.target.value);
            if (message) setMessage(null);
          }}
          className={`flex-1 rounded-lg border px-4 py-3 text-base outline-none transition focus:ring-2 ${inputClass}`}
        />
        <button
          type="submit"
          disabled={status === "submitting"}
          className="rounded-lg bg-signal px-5 py-3 text-base font-medium text-white transition-colors hover:bg-signal-strong focus:outline-none focus:ring-2 focus:ring-signal/40 disabled:opacity-70"
        >
          {status === "submitting" ? "Joining..." : "Join the waitlist"}
        </button>
      </div>
      {message ? (
        <p role="alert" className={`mt-2 text-sm ${helpClass}`}>
          {message}
        </p>
      ) : null}
    </form>
  );
}

function ReferralScreen({ tone, signup }: { tone: Tone; signup: Signup }) {
  const refId = useId();
  const [copied, setCopied] = useState(false);
  const dark = tone === "dark";

  const body = dark ? "text-paper/70" : "text-ink/65";
  const label = dark ? "text-paper" : "text-ink";
  const fieldClass = dark
    ? "bg-white/5 border-white/15 text-paper"
    : "bg-white border-paper-warm text-ink";
  const ghostBtn = dark
    ? "border-white/15 text-paper hover:bg-white/5"
    : "border-paper-warm text-ink hover:bg-paper-warm";
  const ladderBorder = dark ? "border-white/10 divide-white/10" : "border-black/10 divide-black/10";

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(signup.referralLink);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div role="status" aria-live="polite" className="w-full">
      <p className="text-base font-medium text-signal">You&apos;re on the list.</p>
      {signup.position != null ? (
        <p className={`mt-1 text-sm ${body}`}>You&apos;re #{signup.position} in line.</p>
      ) : null}

      <p className={`mt-4 text-sm ${body}`}>
        Want in sooner? Every friend who joins with your link moves you up.
      </p>

      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
        <label htmlFor={refId} className="sr-only">
          Your referral link
        </label>
        <input
          id={refId}
          readOnly
          value={signup.referralLink}
          onFocus={(event) => event.currentTarget.select()}
          className={`flex-1 rounded-lg border px-4 py-2.5 text-sm outline-none ${fieldClass}`}
        />
        <button
          type="button"
          onClick={copyLink}
          className={`rounded-lg border px-4 py-2.5 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-signal/40 ${ghostBtn}`}
        >
          {copied ? "Copied" : "Copy link"}
        </button>
      </div>

      <a
        href={buildXShareUrl(signup.referralLink)}
        target="_blank"
        rel="noopener noreferrer"
        className="mt-3 inline-flex items-center justify-center rounded-lg bg-signal px-5 py-2.5 text-sm font-medium text-white transition-colors hover:bg-signal-strong focus:outline-none focus:ring-2 focus:ring-signal/40"
      >
        Share to X
      </a>

      <ul className={`mt-6 divide-y rounded-lg border ${ladderBorder}`}>
        {REWARDS.map((item) => (
          <li key={item.tier} className="flex gap-3 px-4 py-2.5 text-sm">
            <span className={`w-[4.5rem] shrink-0 font-medium ${label}`}>{item.tier}</span>
            <span className={body}>{item.reward}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
