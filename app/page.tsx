import type { Metadata } from 'next';
import { DocContent } from '@/components/doc-content';
import { SiteShell } from '@/components/site-shell';
import { getDoc } from '@/lib/content';
import { defaultLocale } from '@/lib/i18n';

/** Root `/` renders the default-locale (en) suite home. */
export async function generateMetadata(): Promise<Metadata> {
  const doc = await getDoc(defaultLocale, []);
  return {
    title: { absolute: doc?.title ?? 'Olymposuite Documentation' },
    description:
      doc?.description ??
      'Documentation for the Olymposuite media automation suite.',
  };
}

export default function RootPage() {
  return (
    <SiteShell lang={defaultLocale}>
      <DocContent lang={defaultLocale} slug={[]} />
    </SiteShell>
  );
}
