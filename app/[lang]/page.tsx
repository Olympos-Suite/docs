import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { DocContent } from '@/components/doc-content';
import { getDoc } from '@/lib/content';
import { isLocale } from '@/lib/i18n';

/** Locale home: /<lang> renders content/<lang>/index.md. */
export async function generateMetadata({
  params,
}: {
  params: Promise<{ lang: string }>;
}): Promise<Metadata> {
  const { lang } = await params;
  if (!isLocale(lang)) return {};
  const doc = await getDoc(lang, []);
  return {
    title: { absolute: doc?.title ?? 'Olymposuite Documentation' },
    description:
      doc?.description ??
      'Documentation for the Olymposuite media automation suite.',
  };
}

export default async function LocaleHome({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  if (!isLocale(lang)) notFound();
  return <DocContent lang={lang} slug={[]} />;
}
