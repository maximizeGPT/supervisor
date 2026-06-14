// Product Hunt "Featured" badge for the Supervisor launch.
// Links to the live post and drives upvotes. Theme picks the badge variant so it
// sits on light or dark backgrounds. Plain <img> is the standard PH embed.
const PH_URL =
  "https://www.producthunt.com/products/supervisor-2?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-supervisor-3";
const POST_ID = "1171654";
const ALT =
  "Supervisor - Run Claude Code while you sleep, without babysitting it | Product Hunt";

export default function ProductHuntBadge({
  theme = "light",
  className = "",
}: {
  theme?: "light" | "neutral" | "dark";
  className?: string;
}) {
  return (
    <a
      href={PH_URL}
      target="_blank"
      rel="noopener noreferrer"
      className={`inline-block ${className}`}
      aria-label="Supervisor on Product Hunt"
    >
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={`https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=${POST_ID}&theme=${theme}`}
        alt={ALT}
        width={250}
        height={54}
        style={{ width: "250px", height: "54px" }}
      />
    </a>
  );
}
