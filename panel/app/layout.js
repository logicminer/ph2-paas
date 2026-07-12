import './globals.css';

export const metadata = {
  title: 'PH2 Control Panel',
  description: 'WordPress + Next.js PaaS management',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <div className="min-h-screen">
          <nav className="border-b border-[#2a2e3a] px-6 py-3 flex items-center gap-6">
            <a href="/" className="font-bold text-lg flex items-center gap-2">
              <span className="text-[#3b82f6]">⚡</span>
              PH2 Panel
            </a>
            <div className="flex gap-4 text-sm text-[#8b909c]">
              <a href="/" className="hover:text-[#e4e7ec]">Dashboard</a>
              <a href="/sites" className="hover:text-[#e4e7ec]">Sites</a>
              <a href="/sites/new" className="hover:text-[#e4e7ec]">Spawn WP</a>
            </div>
            <div className="ml-auto text-xs text-[#8b909c]">
              {process.env.BOX_LABEL || 'PH2 PaaS'}
            </div>
          </nav>
          <main className="max-w-6xl mx-auto p-6">
            {children}
          </main>
        </div>
      </body>
    </html>
  );
}
