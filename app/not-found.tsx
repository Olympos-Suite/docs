import Link from 'next/link';
import { Mountain } from 'lucide-react';
import { getDictionary } from '@/lib/dictionary';
import { defaultLocale } from '@/lib/i18n';

export default function NotFound() {
  const dict = getDictionary(defaultLocale);
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-4 px-4 text-center">
      <Mountain className="h-8 w-8 text-accent" aria-hidden />
      <p className="text-sm font-medium tracking-[0.12em] text-zinc-500 uppercase dark:text-zinc-400">
        404
      </p>
      <h1 className="text-3xl font-bold tracking-tight">
        {dict.notFound.title}
      </h1>
      <p className="max-w-[46ch] text-zinc-600 dark:text-zinc-400">
        {dict.notFound.body}
      </p>
      <Link
        href="/"
        className="mt-2 rounded-lg border border-zinc-200 px-4 py-2 text-sm font-medium transition-colors hover:border-accent-border hover:bg-accent-soft dark:border-zinc-800"
      >
        {dict.notFound.back}
      </Link>
    </main>
  );
}
