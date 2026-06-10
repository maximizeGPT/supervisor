// The marker symbol from supervisor-wordmark.svg: a 24-unit squircle frame with a
// filled square in the upper-right corner ("flag" / marker). Rendered as live Inter
// Medium text + this symbol so the lockup stays crisp and recolorable at any size.
const MARKER_PATH =
  "M5,1 H19 A4,4 0 0 1 23,5 V19 A4,4 0 0 1 19,23 H5 A4,4 0 0 1 1,19 V5 A4,4 0 0 1 5,1 Z M5,3 A2,2 0 0 0 3,5 V19 A2,2 0 0 0 5,21 H19 A2,2 0 0 0 21,19 V5 A2,2 0 0 0 19,3 Z M14.1,4.5 H18.9 A0.6,0.6 0 0 1 19.5,5.1 V9.9 A0.6,0.6 0 0 1 18.9,10.5 H14.1 A0.6,0.6 0 0 1 13.5,9.9 V5.1 A0.6,0.6 0 0 1 14.1,4.5 Z";

export default function Wordmark({
  tone = "light",
  className = "",
  symbolClass = "size-8",
  textClass = "text-2xl",
}: {
  tone?: "light" | "dark";
  className?: string;
  symbolClass?: string;
  textClass?: string;
}) {
  const textColor = tone === "dark" ? "text-paper" : "text-ink";
  return (
    <span className={`inline-flex items-center gap-2.5 ${className}`} aria-label="Supervisor">
      <svg viewBox="0 0 24 24" className={`${symbolClass} shrink-0 text-signal`} aria-hidden="true">
        <path fill="currentColor" fillRule="evenodd" d={MARKER_PATH} />
      </svg>
      <span className={`${textClass} font-medium lowercase tracking-[-0.02em] ${textColor}`}>
        supervisor
      </span>
    </span>
  );
}
