"use client";

import { useEffect, useState } from "react";

// Public launch: June 26, 2026, 12:01 AM PDT. The -07:00 offset pins it to PDT
// so the countdown is correct regardless of the visitor's timezone.
const TARGET = Date.parse("2026-06-26T00:01:00-07:00");

const UNITS = [
  { key: "days", label: "Days" },
  { key: "hours", label: "Hrs" },
  { key: "minutes", label: "Min" },
  { key: "seconds", label: "Sec" },
] as const;

function breakdown(ms: number) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return {
    days: Math.floor(s / 86400),
    hours: Math.floor((s % 86400) / 3600),
    minutes: Math.floor((s % 3600) / 60),
    seconds: s % 60,
  };
}

const pad = (n: number) => String(n).padStart(2, "0");

export default function Countdown({ tone = "dark" }: { tone?: "light" | "dark" }) {
  // null until mounted so server and first client render match (no hydration shift).
  const [remaining, setRemaining] = useState<number | null>(null);

  useEffect(() => {
    const update = () => setRemaining(TARGET - Date.now());
    update();
    const id = setInterval(update, 1000);
    return () => clearInterval(id);
  }, []);

  const b = remaining === null ? null : breakdown(remaining);
  const dark = tone === "dark";
  const digitColor = dark ? "text-paper" : "text-ink";
  const labelColor = dark ? "text-paper/45" : "text-mute";
  const sepColor = dark ? "text-paper/25" : "text-ink/25";

  return (
    <div className="flex items-start gap-3 sm:gap-4" aria-label="Time remaining until launch">
      {UNITS.map((u, i) => (
        <div key={u.key} className="flex items-start gap-3 sm:gap-4">
          <div className="flex flex-col items-center">
            <span
              className={`font-mono text-3xl font-semibold tabular-nums leading-none sm:text-4xl ${digitColor}`}
            >
              {b === null ? "--" : pad(b[u.key])}
            </span>
            <span
              className={`mt-2 font-mono text-[0.65rem] font-medium uppercase tracking-[0.2em] ${labelColor}`}
            >
              {u.label}
            </span>
          </div>
          {i < UNITS.length - 1 ? (
            <span
              className={`font-mono text-3xl font-semibold leading-none sm:text-4xl ${sepColor}`}
              aria-hidden="true"
            >
              :
            </span>
          ) : null}
        </div>
      ))}
    </div>
  );
}
