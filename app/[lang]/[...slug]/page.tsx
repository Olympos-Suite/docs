import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { DocContent } from '@/components/doc-content';
import { getAllDocParams, getDoc } from '@/lib/content';
import { isLocale } from '@/lib/i18n';

export const dynamicParams = false;

/**
 * Enumerates every content file per locale: ['zephyrus'] → zephyrus/index.md,
 * ['zephyrus', 'configuration'] → zephyrus/configuration.md. The suite home
 * ([]) is handled by app/[lang]/page.tsx.
 */
export function generateStaticParams() {
  return getAllDocParams();
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ lang: string; slug: string[] }>;
}): Promise<Metadata> {
  const { lang, slug } = await params;
  if (!isLocale(lang)) return {};
  const doc = await getDoc(lang, slug);
  if (!doc) return {};
  return { title: doc.title, description: doc.description };
}

export default async function DocPage({
  params,
}: {
  params: Promise<{ lang: string; slug: string[] }>;
}) {
  const { lang, slug } = await params;
  if (!isLocale(lang)) notFound();
  return <DocContent lang={lang} slug={slug} />;
}
