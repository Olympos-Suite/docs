/**
 * i18n configuration — the single source of truth for locales.
 *
 * Adding a language:
 *   1. Add the locale code to `locales` below.
 *   2. Mirror the content tree under `content/<locale>/`.
 *   3. Add `locales/<locale>.json` with the translated UI strings.
 * No other code changes are required.
 */
export const locales = ['en'] as const;

export type Locale = (typeof locales)[number];

export const defaultLocale: Locale = 'en';

export function isLocale(value: string): value is Locale {
  return (locales as readonly string[]).includes(value);
}
