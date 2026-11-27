import { notFound } from 'next/navigation';
import Link from 'next/link';
import { ChevronRight, Mountain } from 'lucide-react';
import { Markdown } from '@/components/markdown';
import { PrevNext } from '@/components/prev-next';
import { Toc } from '@/components/toc';
import { getAdjacent, getDoc, getSidebar, type Section } from '@/lib/content';
import { getDictionary, type Dictionary } from '@/lib/dictionary';
import type { Locale } from '@/lib/i18n';

/**
 * The document view: breadcrumb, title/description header, markdown prose,
 * prev/next footer, and the right-rail TOC. Used by the root page (en suite
 * home), the locale home, and every catch-all doc page. The suite home gets a
 * slightly larger title, an eyebrow, and a gold rule — presentation only; the
 * markdown body still renders through the same pipeline.
 */
export async function DocContent({
  lang,
  slug,
}: {
  lang: Locale;
  slug: string[];
}) {
  const dict = getDictionary(lang);
  const doc = await getDoc(lang, slug);

  // Graceful fallback: the suite home may not be written yet (parallel lanes).
  if (!doc) {
    if (slug.length === 0) return <HomeFallback lang={lang} dict={dict} />;
    notFound();
  }

  const isHome = slug.length === 0;
  const { prev, next } = getAdjacent(lang, doc.url);
  const sidebar = getSidebar(lang);
  const app = doc.app ? sidebar.apps.find((a) => a.name === doc.app) : null;
  const sectionLabel = (section: Section): string =>
    section === 'User Guide' ? dict.nav.userGuide : dict.nav.developerGuide;

  return (
    <div className="grid gap-10 xl:grid-cols-[minmax(0,1fr)_14rem]">
      <article data-pagefind-body className="min-w-0">
        <div className={isHome ? 'max-w-[76ch]' : 'max-w-[72ch]'}>
          <header className="mb-10">
            {app && (
              <nav
                aria-label="Breadcrumb"
                className="mb-3 flex items-center gap-1.5 text-sm"
              >
                <Link
                  href={app.url}
                  className="font-medium text-zinc-600 transition-colors hover:text-accent dark:text-zinc-400"
                >
                  {app.title}
                </Link>
                {doc.section && (
                  <>
                    <ChevronRight
                      className="h-3.5 w-3.5 text-zinc-400 dark:text-zinc-600"
                      aria-hidden
                    />
                    <span className="text-zinc-500 dark:text-zinc-500">
                      {sectionLabel(doc.section)}
                    </span>
                  </>
                )}
              </nav>
            )}

            {isHome && (
              <p className="mb-3 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.12em] text-accent">
                <Mountain className="h-3.5 w-3.5" aria-hidden />
                {dict.nav.home}
              </p>
            )}

            <h1
              className={`font-bold tracking-tight text-zinc-900 dark:text-zinc-100 ${
                isHome ? 'text-4xl sm:text-5xl' : 'text-3xl sm:text-4xl'
              }`}
            >
              {doc.title}
            </h1>
            {doc.description && (
              <p className="mt-3 max-w-[60ch] text-lg leading-relaxed text-zinc-600 dark:text-zinc-400">
                {doc.description}
              </p>
            )}
            {isHome && (
              <div
                className="mt-6 h-0.5 w-12 rounded-full bg-accent"
                aria-hidden
              />
            )}
          </header>

          <div className="prose max-w-none prose-zinc dark:prose-invert">
            <Markdown body={doc.body} lang={lang} contentPath={doc.contentPath} />
          </div>

          <PrevNext prev={prev} next={next} labels={dict.pager} />
        </div>
      </article>

      <aside className="hidden xl:block">
        <div className="sticky top-20 max-h-[calc(100dvh-6rem)] overflow-y-auto">
          <Toc items={doc.toc} label={dict.nav.onThisPage} />
        </div>
      </aside>
    </div>
  );
}

/** Minimal static intro shown when content/<lang>/index.md does not exist. */
function HomeFallback({ lang, dict }: { lang: Locale; dict: Dictionary }) {
  const sidebar = getSidebar(lang);
  return (
    <article data-pagefind-body className="min-w-0 max-w-3xl">
      <h1 className="text-3xl font-bold tracking-tight">
        {dict.fallback.title}
      </h1>
      <p className="mt-4 text-zinc-600 dark:text-zinc-400">
        {dict.fallback.intro}
      </p>
      {sidebar.apps.length > 0 && (
        <ul className="mt-8 grid gap-3 sm:grid-cols-2">
          {sidebar.apps.map((app) => (
            <li key={app.name}>
              <Link
                href={app.url}
                className="block rounded-xl border border-zinc-200 p-4 transition-colors hover:border-accent-border hover:bg-accent-soft dark:border-zinc-800"
              >
                <span className="font-medium">{app.title}</span>
                {app.home?.description && (
                  <span className="mt-1 block text-sm text-zinc-500 dark:text-zinc-400">
                    {app.home.description}
                  </span>
                )}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </article>
  );
}
