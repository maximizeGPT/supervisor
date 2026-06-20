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

export default function Landing() {
  return (
    <main className="flex flex-col">
      {/* ── HERO (dark Ink, two-column) ────────────────────────────────── */}
      <section className="bg-ink px-6">
        <div className="mx-auto w-full max-w-5xl pt-14 pb-14 sm:pt-20 sm:pb-16">
          <Wordmark tone="dark" />

          <div className="mt-12 grid items-center gap-12 lg:mt-16 lg:grid-cols-2 lg:gap-14">
            {/* Left: copy + single CTA */}
            <div>
              <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-paper/45">
                Early access for macOS
              </p>

              <h1 className="mt-4 max-w-xl text-4xl font-semibold leading-[1.06] tracking-[-0.02em] text-paper sm:text-5xl">
                <span className="text-paper/55">Auto mode takes you out of the loop.</span>{" "}
                Supervisor takes your place.
              </h1>

              <div id="waitlist" className="mt-8 max-w-md scroll-mt-24">
                <WaitlistForm tone="dark" />
                <p className="mt-3 text-sm text-paper/45">One email when it&apos;s ready. No spam.</p>
                {/* When the signed .dmg ships, add a real Download button here. */}
                <p className="mt-1 text-xs text-paper/35">macOS 13 or later. Download coming soon.</p>
              </div>

              <div className="mt-9">
                <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-paper/45">
                  Launches June 26, 2026
                </p>
                <div className="mt-4">
                  <Countdown tone="dark" />
                </div>
              </div>
            </div>

            {/* Right: vertical teaser (stacks under the copy on mobile) */}
            <div className="flex justify-center lg:justify-end">
              <figure className="w-full max-w-[320px]">
                <div className="overflow-hidden rounded-2xl border border-white/10 shadow-2xl shadow-black/40">
                  {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
                  <video
                    className="block aspect-[9/16] w-full bg-black"
                    controls
                    playsInline
                    preload="metadata"
                    poster="/supervisor-demo-poster.jpg"
                    aria-label="Supervisor teaser"
                  >
                    <source src="/supervisor-demo.mp4" type="video/mp4" />
                  </video>
                </div>
                <figcaption className="mt-3 text-center text-sm text-paper/45">
                  What Supervisor does, in under a minute.
                </figcaption>
              </figure>
            </div>
          </div>

          {/* Works-with strip (pills relocated out of the hero stack) */}
          <div className="mt-12 flex flex-wrap items-center gap-3 border-t border-white/5 pt-6 lg:mt-14">
            <span className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-paper/35">
              Works with
            </span>
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
        </div>
      </section>

      {/* ── SEE IT WORK (full-width landscape demo) ────────────────────── */}
      <section className="bg-paper px-6 py-20 sm:py-24">
        <div className="mx-auto w-full max-w-4xl">
          <Eyebrow>See it work</Eyebrow>
          <figure className="mt-8">
            <div className="overflow-hidden rounded-2xl border border-black/10 shadow-2xl shadow-black/20">
              {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
              <video
                className="block aspect-video w-full bg-black"
                controls
                playsInline
                preload="metadata"
                poster="/supervisor-demo-landscape-poster.jpg"
                aria-label="Supervisor demo"
              >
                <source src="/supervisor-demo-landscape.mp4" type="video/mp4" />
              </video>
            </div>
            <figcaption className="mt-4 text-center text-sm text-ink/50">
              Supervisor answers a question, then catches a risky command. In real time.
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
          <p className="mt-5 max-w-2xl text-lg leading-relaxed text-ink/70">
            It reads your repo to answer Claude Code&apos;s questions in plain language,
            keeps the session moving, and steps in the moment an action looks destructive.
          </p>
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
