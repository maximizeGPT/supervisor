import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";

// Brand type system: Inter (400/500/600) for everything, JetBrains Mono for
// code/terminal snippets. Loaded via next/font so there is no layout shift.
const inter = Inter({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-inter",
  display: "swap",
});

const jetbrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-jetbrains-mono",
  display: "swap",
});

export const metadata: Metadata = {
  // TODO: set to your production domain before deploy (used for absolute OG URLs).
  metadataBase: new URL("https://supervisor.app"),
  title: "Supervisor",
  description:
    "Auto-accept takes you out of the loop. Supervisor takes your place: it reads your repo to answer Claude Code's questions, keeps the session moving, and steps in when an action looks destructive.",
  openGraph: {
    title: "Supervisor",
    description:
      "Auto-accept takes you out of the loop. Supervisor takes your place, answering Claude Code's questions, keeping the session moving, and stepping in when an action looks destructive.",
    type: "website",
    images: [{ url: "/branding/supervisor-social-card.png", width: 1280, height: 640 }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Supervisor",
    description:
      "Auto-accept takes you out of the loop. Supervisor takes your place: it answers Claude Code's questions, keeps the session moving, and steps in when an action looks destructive.",
    images: ["/branding/supervisor-social-card.png"],
  },
  icons: {
    icon: "/branding/supervisor-appicon-1024.png",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrainsMono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
