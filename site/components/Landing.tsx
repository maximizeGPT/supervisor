import WaitlistForm from "@/components/WaitlistForm";
import Wordmark from "@/components/Wordmark";
import ProductHuntBadge from "@/components/ProductHuntBadge";
import Countdown from "@/components/Countdown";

const FEATURES = [
  {
    title: "Answers the questions",
    body:
      "When Claude Code stops to ask, Supervisor reads the repo and answers in the session, in plain language. You stop being the bottleneck.",
  },
  {
    title: "Keeps it moving",
    body:
      "Supervisor keeps a session going on its own instead of stalling the moment you step away.",
  },
  {
    title: "Stops the dangerous stuff",
    body:
      "When an action looks destructive, Supervisor pauses and tells you why, in a sentence you can actually read.",
  },
];

const PRICING_POINTS = [
  {
    title: "$0 for the app",
    body:
      "No license fee, no subscription, no per-seat pricing. Download Supervisor and run it.",
  },
  {
    title: "You bring the key",
    body:
      "It runs on the API key you already have, so your usage is billed to you directly, at cost. We never touch it.",
  },
  {
    title: "No account, no lock-in",
    body:
      "Nothing to sign up for and nothing to cancel. Your machine, your key, your data.",
  },
];

function Eyebrow({ children }: { children: React.ReactNode }) {
  return (
    <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-mute">
      {children}
    </p>
  );
}

function ParkedDownload() {
  return (
    // Parked download CTA. The signed build does not exist yet.
    // >>> When the .dmg is ready, replace this <button> with a real link:
    //        <a href="https://YOUR-CDN/Supervisor.dmg" download className="...">Download for macOS</a>
    //     and delete the "Available soon" tag. <<<
    <button
      type="button"
      disabled
      aria-disabled="true"
      className="inline-flex cursor-not-allowed items-center gap-2 text-sm font-medium text-paper/45"
    >
      Download for macOS
      <span className="rounded-full border border-white/15 px-2 py-0.5 text-xs text-paper/45">
        Available soon
      </span>
    </button>
  );
}

export default function Landing() {
  return (
    <main className="flex flex-col">
      {/* ── HERO (dark Ink) ────────────────────────────────────────────── */}
      <section className="bg-ink px-6">
        <div className="mx-auto w-full max-w-5xl pt-14 pb-20 sm:pt-20 sm:pb-28">
          <Wordmark tone="dark" />

          <p className="mt-14 font-mono text-xs font-medium uppercase tracking-[0.2em] text-paper/45 sm:mt-20">
            Early access for macOS
          </p>

          <h1 className="mt-4 max-w-3xl text-4xl font-semibold leading-[1.06] tracking-[-0.02em] text-paper sm:text-5xl lg:text-[3.5rem]">
            <span className="text-paper/55">Auto mode takes you out of the loop.</span>{" "}
            Supervisor takes your place.
          </h1>

          <div className="mt-7 flex flex-wrap items-center gap-3">
            <span className="inline-flex items-center gap-2 rounded-full border border-white/15 px-3.5 py-1.5 text-sm text-paper">
              <span className="size-1.5 rounded-full bg-signal" aria-hidden="true" />
              Claude Code
              <span className="text-paper/45">Supported now</span>
            </span>
            <span className="inline-flex items-center gap-2 rounded-full border border-white/10 px-3.5 py-1.5 text-sm text-paper/70">
              Codex
              <span className="rounded-full bg-signal/15 px-2 py-0.5 text-xs font-medium text-signal">
                Coming soon
              </span>
            </span>
          </div>

          <p className="mt-6 max-w-xl text-lg leading-relaxed text-paper/70 sm:text-xl">
            It reads your repo to answer Claude Code&apos;s questions in plain
            language, keeps the session moving, and steps in the moment an action
            looks destructive.
          </p>

          <div className="mt-8">
            <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-paper/45">
              Launches June 26, 2026
            </p>
            <div className="mt-4">
              <Countdown tone="dark" />
            </div>
          </div>

          <div id="waitlist" className="mt-9 max-w-md scroll-mt-24">
            <WaitlistForm tone="dark" />
            <p className="mt-3 text-sm text-paper/45">One email when it&apos;s ready. No spam.</p>
            <div className="mt-5">
              <ParkedDownload />
            </div>
            <div className="mt-6">
              <ProductHuntBadge theme="dark" />
            </div>
          </div>

          {/* Demo: vertical founder walkthrough (sound on). Click-to-play with controls,
              poster shown until played so the page stays light. Swap /public/supervisor-demo.mp4
              + supervisor-demo-poster.jpg to update. */}
          <figure className="mt-14 sm:mt-16">
            <div className="mx-auto w-full max-w-[340px] overflow-hidden rounded-2xl border border-white/10 shadow-2xl shadow-black/40">
              {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
              <video
                className="block aspect-[9/16] w-full bg-black"
                controls
                playsInline
                preload="metadata"
                poster="/supervisor-demo-poster.jpg"
                aria-label="Supervisor walkthrough"
              >
                <source src="/supervisor-demo.mp4" type="video/mp4" />
              </video>
            </div>
            <figcaption className="mt-3 text-center text-sm text-paper/45">
              What Supervisor does, in under a minute.
            </figcaption>
          </figure>
        </div>
      </section>

      {/* ── PROBLEM ────────────────────────────────────────────────────── */}
      <section className="border-y border-black/5 bg-paper-warm px-6 py-20 sm:py-24">
        <div className="mx-auto w-full max-w-3xl">
          <Eyebrow>The problem</Eyebrow>
          <p className="mt-5 text-xl leading-relaxed text-ink/80 sm:text-2xl sm:leading-relaxed">
            Running Claude Code unattended is great until it stops to ask a question
            you&apos;re not there to answer, or does something you didn&apos;t want. So
            you end up watching the terminal instead of doing your work.
          </p>
        </div>
      </section>

      {/* ── WHAT IT DOES ───────────────────────────────────────────────── */}
      <section className="bg-paper px-6 py-20 sm:py-24">
        <div className="mx-auto w-full max-w-5xl">
          <Eyebrow>What it does</Eyebrow>
          <div className="mt-10 grid gap-10 sm:grid-cols-3 sm:gap-8">
            {FEATURES.map((feature) => (
              <div key={feature.title} className="border-t border-black/10 pt-5">
                <h2 className="text-lg font-semibold text-ink">{feature.title}</h2>
                <p className="mt-3 leading-relaxed text-ink/70">{feature.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── HOW IT WORKS / REQUIREMENTS ────────────────────────────────── */}
      <section className="border-y border-black/5 bg-paper-warm px-6 py-20 sm:py-24">
        <div className="mx-auto w-full max-w-3xl">
          <Eyebrow>How it works</Eyebrow>
          <p className="mt-5 text-lg leading-relaxed text-ink/80 sm:text-xl">
            macOS 13 or later. Bring your own Anthropic API key. Supervisor runs
            entirely on your Mac. Nothing leaves your machine except the same API
            calls you&apos;d make yourself.
          </p>
        </div>
      </section>

      {/* ── PRICING (free, bring your own key) ─────────────────────────── */}
      <section className="bg-paper px-6 py-20 sm:py-24">
        <div className="mx-auto w-full max-w-5xl">
          <Eyebrow>Pricing</Eyebrow>
          <h2 className="mt-5 max-w-2xl text-3xl font-semibold tracking-[-0.02em] text-ink">
            <span className="text-signal">Free.</span> Bring your own key.
          </h2>
          <p className="mt-5 max-w-2xl text-lg leading-relaxed text-ink/70">
            Supervisor is free to download and run. The only thing you pay for is
            the usage you&apos;d have paid for anyway, at cost, and never to us.
          </p>
          <div className="mt-10 grid gap-10 sm:grid-cols-3 sm:gap-8">
            {PRICING_POINTS.map((point) => (
              <div key={point.title} className="border-t border-black/10 pt-5">
                <h3 className="text-lg font-semibold text-ink">{point.title}</h3>
                <p className="mt-3 leading-relaxed text-ink/70">{point.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── CLOSING / REPEAT CAPTURE ───────────────────────────────────── */}
      <section className="border-t border-black/5 bg-paper-warm px-6 py-20 sm:py-24">
        <div className="mx-auto w-full max-w-2xl">
          <h2 className="text-3xl font-semibold tracking-[-0.02em] text-ink">
            Join the waitlist
          </h2>
          <p className="mt-3 text-ink/65">
            Get the download link when Supervisor is ready.
          </p>
          <div className="mt-7 max-w-xl">
            <WaitlistForm tone="light" />
          </div>
        </div>
      </section>

      {/* ── FOOTER ─────────────────────────────────────────────────────── */}
      <footer className="border-t border-black/10 bg-paper px-6 py-10">
        <div className="mx-auto flex w-full max-w-5xl flex-col gap-6">
          <ProductHuntBadge theme="light" />
          <div className="flex w-full flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <Wordmark tone="light" symbolClass="size-5" textClass="text-base" />
            <span className="text-sm text-mute">Runs on your Mac. macOS 13 or later.</span>
          </div>
        </div>
      </footer>
    </main>
  );
}
