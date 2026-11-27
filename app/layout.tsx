import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import './globals.css';

export const metadata: Metadata = {
  title: {
    default: 'Olymposuite Documentation',
    template: '%s · Olymposuite',
  },
  description:
    'Documentation for the Olymposuite media automation suite: Zephyrus, Eros, Psyche, and Morpheus.',
};

/**
 * Sets the theme class before first paint: stored preference wins, then
 * prefers-color-scheme, defaulting to dark. No flash, no hydration mismatch
 * (html carries suppressHydrationWarning).
 */
const themeScript = `(function () {
  try {
    var stored = localStorage.getItem('theme');
    var dark = stored
      ? stored === 'dark'
      : !window.matchMedia('(prefers-color-scheme: light)').matches;
    document.documentElement.classList.toggle('dark', dark);
  } catch (e) {
    document.documentElement.classList.add('dark');
  }
})();`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="bg-white text-zinc-900 antialiased dark:bg-zinc-950 dark:text-zinc-100">
        {children}
      </body>
    </html>
  );
}
