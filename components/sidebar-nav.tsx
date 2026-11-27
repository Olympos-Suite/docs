'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import type { Dictionary } from '@/lib/dictionary';
import type { DocMeta, Section, Sidebar } from '@/lib/content';

/**
 * Sidebar navigation tree (client component only for active-link highlighting;
 * the tree itself is computed at build time in lib/content.ts and passed in as
 * plain data). Suite home first, apps in fixed order, sections sorted by order.
 * The active page carries the suite's gold accent; sections are quiet uppercase
 * labels so the hierarchy reads app → section → page at a glance.
 */

function normalize(path: string): string {
  return path.length > 1 ? path.replace(/\/+$/, '') : path;
}

function NavLink({ doc, active }: { doc: DocMeta; active: boolean }) {
  return (
    <Link
      href={doc.url}
      aria-current={active ? 'page' : undefined}
      className={`block rounded-md border-l-2 px-2.5 py-2 text-sm transition-colors ${
        active
          ? 'border-accent bg-accent-soft font-medium text-accent'
          : 'border-transparent text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900 dark:text-zinc-400 dark:hover:bg-zinc-900 dark:hover:text-zinc-100'
      }`}
    >
      {doc.title}
    </Link>
  );
}

export function SidebarNav({
  sidebar,
  dict,
}: {
  sidebar: Sidebar;
  dict: Dictionary;
}) {
  const pathname = normalize(usePathname());
  const sectionLabel = (label: Section): string =>
    label === 'User Guide' ? dict.nav.userGuide : dict.nav.developerGuide;

  return (
    <nav aria-label={dict.nav.documentation} className="text-sm">
      {sidebar.home && (
        <NavLink
          doc={sidebar.home}
          active={pathname === normalize(sidebar.home.url)}
        />
      )}

      {sidebar.apps.map((app) => {
        const appActive = pathname === normalize(app.url);
        return (
          <div key={app.name} className="mt-6">
            <Link
              href={app.url}
              aria-current={appActive ? 'page' : undefined}
              className={`flex items-center gap-2 rounded-md px-2.5 py-1.5 text-[13px] font-semibold tracking-tight transition-colors ${
                appActive
                  ? 'text-accent'
                  : 'text-zinc-800 hover:text-zinc-950 dark:text-zinc-200 dark:hover:text-white'
              }`}
            >
              <span
                className={`h-1.5 w-1.5 flex-none rounded-full transition-colors ${
                  appActive ? 'bg-accent' : 'bg-zinc-300 dark:bg-zinc-700'
                }`}
                aria-hidden
              />
              {app.title}
            </Link>

            {app.sections.map((section) => (
              <div key={section.label} className="mt-2">
                <p className="px-2.5 pb-1 text-[11px] font-medium uppercase tracking-[0.08em] text-zinc-400 dark:text-zinc-500">
                  {sectionLabel(section.label)}
                </p>
                <ul className="space-y-0.5">
                  {section.items.map((doc) => (
                    <li key={doc.url}>
                      <NavLink
                        doc={doc}
                        active={pathname === normalize(doc.url)}
                      />
                    </li>
                  ))}
                </ul>
              </div>
            ))}

            {app.ungrouped.length > 0 && (
              <ul className="mt-2 space-y-0.5">
                {app.ungrouped.map((doc) => (
                  <li key={doc.url}>
                    <NavLink
                      doc={doc}
                      active={pathname === normalize(doc.url)}
                    />
                  </li>
                ))}
              </ul>
            )}
          </div>
        );
      })}
    </nav>
  );
}
