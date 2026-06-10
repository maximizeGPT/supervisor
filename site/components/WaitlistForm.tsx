"use client";

import { useId, useState } from "react";

/* ── Waitlist endpoint ─────────────────────────────────────────────────────
   No backend. The form POSTs to a single pluggable endpoint.

   >>> PASTE YOUR REAL ENDPOINT HERE <<<
   Either set NEXT_PUBLIC_WAITLIST_ENDPOINT in .env.local, e.g.
       NEXT_PUBLIC_WAITLIST_ENDPOINT=https://formspree.io/f/abcdwxyz
   or replace the PLACEHOLDER string below directly.

   Until a real endpoint is set, the form validates the email and shows the
   success state locally WITHOUT sending anything anywhere (demo mode).        */
const WAITLIST_ENDPOINT =
  process.env.NEXT_PUBLIC_WAITLIST_ENDPOINT ?? "https://formspree.io/f/PLACEHOLDER";

const IS_DEMO = WAITLIST_ENDPOINT.includes("PLACEHOLDER");

// Client-side email validation (one address, has an @ and a dotted domain).
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

type Status = "idle" | "submitting" | "success" | "error";

export default function WaitlistForm({ tone = "light" }: { tone?: "light" | "dark" }) {
  const inputId = useId();
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>("idle");
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = email.trim();

    if (!EMAIL_RE.test(value)) {
      setMessage("Enter a valid email address.");
      return;
    }
    setMessage(null);
    setStatus("submitting");

    // Demo mode: no endpoint wired up yet, so just confirm locally.
    if (IS_DEMO) {
      setStatus("success");
      return;
    }

    try {
      const res = await fetch(WAITLIST_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ email: value }),
      });
      if (res.ok) {
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

  const inputClass =
    tone === "dark"
      ? "bg-white/5 border-white/15 text-paper placeholder:text-paper/40 focus:border-signal focus:ring-signal/40"
      : "bg-white border-paper-warm text-ink placeholder:text-mute focus:border-signal focus:ring-signal/30";
  const helpClass = tone === "dark" ? "text-paper/60" : "text-ink/55";

  if (status === "success") {
    return (
      <p role="status" className="text-base font-medium text-signal">
        {"You're on the list."}
      </p>
    );
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
