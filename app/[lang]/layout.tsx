import { notFound } from 'next/navigation';
import type { ReactNode } from 'react';
import { HtmlLang } from '@/components/html-lang';
import { SiteShell } from '@/components/site-shell';
import { isLocale, locales } from '@/lib/i18n';

export const dynamicParams = false;

export function generateStaticParams() {
  return locales.map((lang) => ({ lang }));
}

export default async function LangLayout({
  params,
  children,
}: {
  params: Promise<{ lang: string }>;
  children: ReactNode;
}) {
  const { lang } = await params;
  if (!isLocale(lang)) notFound();

  return (
    <>
      <HtmlLang lang={lang} />
      <SiteShell lang={lang}>{children}</SiteShell>
    </>
  );
}
