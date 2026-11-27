import { ArrowLeft, ArrowRight } from 'lucide-react';
import Link from 'next/link';
import type { DocMeta } from '@/lib/content';
import type { Dictionary } from '@/lib/dictionary';

/** Prev/next footer across the flattened reading order. */
export function PrevNext({
  prev,
  next,
  labels,
}: {
  prev: DocMeta | null;
  next: DocMeta | null;
  labels: Dictionary['pager'];
}) {
  if (!prev && !next) return null;
  return (
    <nav
      aria-label="Pagination"
      className="mt-14 grid gap-4 border-t border-zinc-200 pt-8 sm:grid-cols-2 dark:border-zinc-800"
    >
      {prev ? (
        <Link
          href={prev.url}
          className="group flex flex-col gap-1.5 rounded-xl border border-zinc-200 p-4 transition-colors hover:border-accent-border hover:bg-accent-soft dark:border-zinc-800"
        >
          <span className="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-[0.08em] text-zinc-500 dark:text-zinc-400">
            <ArrowLeft
              className="h-3.5 w-3.5 transition-transform group-hover:-translate-x-0.5"
              aria-hidden
            />
            {labels.previous}
          </span>
          <span className="font-medium text-zinc-900 dark:text-zinc-100">
            {prev.title}
          </span>
        </Link>
      ) : (
        <span aria-hidden />
      )}
      {next ? (
        <Link
          href={next.url}
          className="group flex flex-col items-end gap-1.5 rounded-xl border border-zinc-200 p-4 text-right transition-colors hover:border-accent-border hover:bg-accent-soft sm:col-start-2 dark:border-zinc-800"
        >
          <span className="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-[0.08em] text-zinc-500 dark:text-zinc-400">
            {labels.next}
            <ArrowRight
              className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5"
              aria-hidden
            />
          </span>
          <span className="font-medium text-zinc-900 dark:text-zinc-100">
            {next.title}
          </span>
        </Link>
      ) : (
        <span aria-hidden />
      )}
    </nav>
  );
}
