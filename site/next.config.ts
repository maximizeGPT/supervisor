import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Hide the dev-only activity indicator so local screenshots are clean.
  devIndicators: false,
};

export default nextConfig;
