/** @type {import('next').NextConfig} */
module.exports = {
  // Panel runs behind Dokku's nginx reverse proxy + cloudflared
  // Trust the X-Forwarded headers
  experimental: {},
  // better-sqlite3 is a native module — don't let webpack try to bundle it
  webpack: (config, { isServer }) => {
    if (!isServer) {
      config.resolve.fallback = { ...config.resolve.fallback, fs: false };
    }
    return config;
  },
};
