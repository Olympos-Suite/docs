'use client';

import { useEffect, useState } from 'react';
import type { TocItem } from '@/lib/content';

/**
 * Right-rail table of contents (h2/h3). Ids come from rehype-slug via the
 * loader; a lightweight IntersectionObserver tracks the active heading, which
 * is marked with the suite accent and aria-current for assistive tech.
 */
export function Toc({ items, label }: { items: TocItem[]; label: string }) {
  const [active, setActive] = useState<string | null>(null);

  useEffect(() => {
    const headings = items
      .map((item) => document.getElementById(item.id))
      .filter((el): el is HTMLElement => el !== null);
    if (headings.length === 0) return;

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) setActive(entry.target.id);
        }
      },
      { rootMargin: '-80px 0px -70% 0px' },
    );
    headings.forEach((heading) => observer.observe(heading));
    return () => observer.disconnect();
  }, [items]);

  if (items.length === 0) return null;

  return (
    <nav aria-label={label} className="text-[13px]">
      <p className="pb-2 text-[11px] font-medium uppercase tracking-[0.08em] text-zinc-400 dark:text-zinc-500">
        {label}
      </p>
      <ul className="space-y-0.5 border-l border-zinc-200 dark:border-zinc-800">
        {items.map((item) => {
          const isActive = active === item.id;
          return (
            <li key={item.id} className={item.depth === 3 ? 'pl-5' : 'pl-3'}>
              <a
                href={`#${item.id}`}
                aria-current={isActive ? 'location' : undefined}
                className={`-ml-px block border-l-2 py-1 pl-3 transition-colors ${
                  isActive
                    ? 'border-accent font-medium text-accent'
                    : 'border-transparent text-zinc-500 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100'
                }`}
              >
                {item.text}
              </a>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
