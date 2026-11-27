import type { ReactNode } from 'react';
import Link from 'next/link';
import { SidebarNav } from '@/components/sidebar-nav';
import { SiteHeader } from '@/components/site-header';
import { getSidebar } from '@/lib/content';
import { getDictionary } from '@/lib/dictionary';
import type { Locale } from '@/lib/i18n';

/**
 * Page chrome shared by every route: sticky header, left sidebar (drawer on
 * mobile), the main content column, and a slim footer. The root page and the
 * [lang] layout both render this shell for their locale.
 */
export function SiteShell({
  lang,
  children,
}: {
  lang: Locale;
  children: ReactNode;
}) {
  const dict = getDictionary(lang);
  const sidebar = getSidebar(lang);
  const nav = <SidebarNav sidebar={sidebar} dict={dict} />;

  return (
    <div className="flex min-h-dvh flex-col">
      <SiteHeader lang={lang} dict={dict} nav={nav} />
      <div className="mx-auto grid w-full max-w-[90rem] flex-1 lg:grid-cols-[16rem_minmax(0,1fr)]">
        <aside className="hidden border-r border-zinc-200 lg:block dark:border-zinc-800">
          <div className="sticky top-14 max-h-[calc(100dvh-3.5rem)] overflow-y-auto p-4">
            {nav}
          </div>
        </aside>
        <main className="min-w-0 px-4 py-8 lg:px-12 lg:py-10">
          {children}
          <footer className="mt-16 flex flex-col gap-2 border-t border-zinc-200 pt-6 text-xs text-zinc-500 sm:flex-row sm:items-center sm:justify-between dark:border-zinc-800">
            <span>
              {dict.site.title} · {dict.site.tagline}
            </span>
            <span className="flex flex-wrap items-center gap-x-3 gap-y-1">
              {sidebar.apps.map((app) => (
                <Link
                  key={app.name}
                  href={app.url}
                  className="transition-colors hover:text-accent"
                >
                  {app.title}
                </Link>
              ))}
            </span>
          </footer>
        </main>
      </div>
    </div>
  );
}
