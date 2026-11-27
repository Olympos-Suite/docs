'use client';

import { Moon, Sun } from 'lucide-react';
import { iconButtonClass } from '@/components/control-styles';

/**
 * Class-based theme toggle. The initial class is set by an inline script in
 * app/layout.tsx (localStorage → prefers-color-scheme → default dark), so the
 * icons are swapped with CSS only — no hydration mismatch.
 */
export function ThemeToggle({ label }: { label: string }) {
  const toggle = () => {
    const dark = document.documentElement.classList.toggle('dark');
    try {
      localStorage.setItem('theme', dark ? 'dark' : 'light');
    } catch {
      // Storage unavailable (private mode etc.) — class toggle still works.
    }
  };

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={label}
      title={label}
      className={iconButtonClass}
    >
      <Moon className="h-4 w-4 dark:hidden" aria-hidden />
      <Sun className="hidden h-4 w-4 dark:block" aria-hidden />
    </button>
  );
}
