'use client';

import { Languages } from 'lucide-react';
import { usePathname, useRouter } from 'next/navigation';
import { isLocale, type Locale } from '@/lib/i18n';

const shellClass =
  'inline-flex h-9 items-center gap-1.5 rounded-lg border border-zinc-200 px-2.5 text-sm transition-colors dark:border-zinc-800';

/**
 * Swaps the first path segment to change locale, preserving the rest of the
 * path. With a single locale the control renders disabled but stays mounted,
 * so adding a language requires no component changes.
 */
export function LanguageSwitcher({
  locales,
  current,
  label,
}: {
  locales: readonly Locale[];
  current: Locale;
  label: string;
}) {
  const pathname = usePathname();
  const router = useRouter();

  if (locales.length < 2) {
    return (
      <button
        type="button"
        disabled
        aria-label={label}
        title={label}
        className={`${shellClass} cursor-not-allowed text-zinc-400 opacity-60 dark:text-zinc-600`}
      >
        <Languages className="h-4 w-4" aria-hidden />
        {current.toUpperCase()}
      </button>
    );
  }

  const switchTo = (locale: Locale) => {
    const parts = pathname.split('/').filter(Boolean);
    const rest = isLocale(parts[0] ?? '') ? parts.slice(1) : parts;
    router.push(`/${locale}${rest.length > 0 ? `/${rest.join('/')}` : ''}`);
  };

  return (
    <label
      className={`${shellClass} text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-900`}
    >
      <Languages className="h-4 w-4" aria-hidden />
      <span className="sr-only">{label}</span>
      <select
        value={current}
        onChange={(event) => switchTo(event.target.value as Locale)}
        className="bg-transparent outline-none"
        aria-label={label}
      >
        {locales.map((locale) => (
          <option key={locale} value={locale}>
            {locale.toUpperCase()}
          </option>
        ))}
      </select>
    </label>
  );
}
