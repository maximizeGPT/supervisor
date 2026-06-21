"use client";

import Script from "next/script";
import { useEffect } from "react";
import { track } from "@vercel/analytics";

/* Ad-platform pixels are opt-in via env vars (NEXT_PUBLIC_*, inlined at build
   time). Set the ones you actually run ads on in Vercel and redeploy; any unset
   one stays completely inert. Pixels fire PageView for retargeting audiences.
   A true per-signup conversion event is NOT firable here: the LaunchList form is
   a cross-origin iframe that emits no success signal. Accurate signup conversions
   need LaunchList's webhook -> a server-side conversion API (a follow-up). */
const META = process.env.NEXT_PUBLIC_META_PIXEL_ID;
const TWITTER = process.env.NEXT_PUBLIC_TWITTER_PIXEL_ID;
const GTAG = process.env.NEXT_PUBLIC_GTAG_ID; // GA4 measurement id (G-...) or Google Ads id (AW-...)

export default function Tracking() {
  useEffect(() => {
    // First-touch attribution: stash UTM + referrer so a later signup/webhook can read it.
    try {
      const q = new URLSearchParams(window.location.search);
      const utm: Record<string, string> = {};
      ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"].forEach((k) => {
        const v = q.get(k);
        if (v) utm[k] = v;
      });
      if (Object.keys(utm).length > 0 && !document.cookie.includes("sv_attr=")) {
        const payload = JSON.stringify({ ...utm, referrer: document.referrer || "", ts: new Date().toISOString() });
        document.cookie = `sv_attr=${encodeURIComponent(payload)};path=/;max-age=${60 * 60 * 24 * 90};samesite=lax`;
      }
    } catch {
      // attribution is best-effort; never block the page
    }

    // Soft funnel signal: the LaunchList signup form is a cross-origin iframe, so a
    // confirmed signup is not observable. We can at least record that a visitor
    // engaged the form (clicked into it), once per session.
    let fired = false;
    const onBlur = () => {
      window.setTimeout(() => {
        const el = document.activeElement as HTMLIFrameElement | null;
        if (!fired && el && el.tagName === "IFRAME" && (el.src || "").includes("getlaunchlist")) {
          fired = true;
          track("waitlist_engaged");
        }
      }, 0);
    };
    window.addEventListener("blur", onBlur);
    return () => window.removeEventListener("blur", onBlur);
  }, []);

  return (
    <>
      {META ? (
        <Script id="meta-pixel" strategy="afterInteractive">
          {`!function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?n.callMethod.apply(n,arguments):n.queue.push(arguments)};if(!f._fbq)f._fbq=n;n.push=n;n.loaded=!0;n.version='2.0';n.queue=[];t=b.createElement(e);t.async=!0;t.src=v;s=b.getElementsByTagName(e)[0];s.parentNode.insertBefore(t,s)}(window,document,'script','https://connect.facebook.net/en_US/fbevents.js');fbq('init','${META}');fbq('track','PageView');`}
        </Script>
      ) : null}
      {TWITTER ? (
        <Script id="twitter-pixel" strategy="afterInteractive">
          {`!function(e,t,n,s,u,a){e.twq||(s=e.twq=function(){s.exe?s.exe.apply(s,arguments):s.queue.push(arguments)},s.version='1.1',s.queue=[],u=t.createElement(n),u.async=!0,u.src='https://static.ads-twitter.com/uwt.js',a=t.getElementsByTagName(n)[0],a.parentNode.insertBefore(u,a))}(window,document,'script');twq('config','${TWITTER}');`}
        </Script>
      ) : null}
      {GTAG ? (
        <>
          <Script src={`https://www.googletagmanager.com/gtag/js?id=${GTAG}`} strategy="afterInteractive" />
          <Script id="gtag-init" strategy="afterInteractive">
            {`window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','${GTAG}');`}
          </Script>
        </>
      ) : null}
    </>
  );
}
