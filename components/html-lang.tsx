'use client';

import { useEffect } from 'react';
import type { Locale } from '@/lib/i18n';

/** Keeps <html lang> in sync with the active locale (root layout owns <html>). */
export function HtmlLang({ lang }: { lang: Locale }) {
  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);
  return null;
}
