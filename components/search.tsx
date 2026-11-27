'use client';

import { Search as SearchIcon, X } from 'lucide-react';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useDialog } from '@/components/use-dialog';
import type { Dictionary } from '@/lib/dictionary';

/**
 * Pagefind search modal. Pagefind indexes the static export in `postbuild`
 * and emits its UI bundle to `out/pagefind/`. We load that bundle at runtime
 * (script + stylesheet) instead of bundling it, so dev — where /pagefind does
 * not exist — degrades to a friendly "available after build" message.
 *
 * Open state is owned by SiteHeader (controlled) so the search modal and the
 * mobile drawer can never be open at the same time — exactly one focus trap.
 */

interface PagefindUIOptions {
  element: HTMLElement | string;
  bundlePath?: string;
  showSubResults?: boolean;
  showImages?: boolean;
  resetStyles?: boolean;
}

declare global {
  interface Window {
    PagefindUI?: new (options: PagefindUIOptions) => unknown;
  }
}

let uiPromise: Promise<void> | null = null;

function loadPagefindUI(): Promise<void> {
  if (uiPromise) return uiPromise;
  uiPromise = new Promise<void>((resolve, reject) => {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = '/pagefind/pagefind-ui.css';
    document.head.appendChild(link);

    const script = document.createElement('script');
    script.src = '/pagefind/pagefind-ui.js';
    script.onload = () => resolve();
    script.onerror = () => {
      uiPromise = null;
      link.remove();
      script.remove();
      reject(new Error('Pagefind bundle not found'));
    };
    document.head.appendChild(script);
  });
  return uiPromise;
}

export function Search({
  strings,
  open,
  onOpenChange,
}: {
  strings: Dictionary['search'];
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [status, setStatus] = useState<
    'idle' | 'loading' | 'ready' | 'unavailable'
  >('idle');
  const dialogRef = useRef<HTMLDivElement>(null);
  const pagefindRef = useRef<HTMLDivElement>(null);

  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  useDialog({ open, onClose: close, containerRef: dialogRef });

  // Instantiate PagefindUI into the freshly mounted container each time the
  // modal opens. The container unmounts on close, so a one-time init would
  // leave a stale, detached node and an empty box on reopen. The bundle itself
  // loads once (loadPagefindUI caches the script/stylesheet promise).
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    // Deferred so no setState runs synchronously in the effect body; it still
    // lands before the (cached) bundle promise resolves.
    queueMicrotask(() => {
      if (!cancelled) setStatus('loading');
    });
    loadPagefindUI()
      .then(() => {
        if (cancelled || !pagefindRef.current || !window.PagefindUI) return;
        new window.PagefindUI({
          element: pagefindRef.current,
          bundlePath: '/pagefind/',
          showSubResults: true,
          showImages: false,
        });
        setStatus('ready');
        pagefindRef.current.querySelector('input')?.focus();
      })
      .catch(() => {
        if (!cancelled) setStatus('unavailable');
      });
    return () => {
      cancelled = true;
    };
  }, [open]);

  return (
    <>
      <button
        type="button"
        onClick={() => onOpenChange(true)}
        aria-label={strings.button}
        aria-expanded={open}
        className="inline-flex h-9 items-center gap-2 rounded-lg border border-zinc-200 px-3 text-sm text-zinc-500 transition-colors hover:bg-zinc-100 hover:text-zinc-700 sm:min-w-[13rem] dark:border-zinc-800 dark:text-zinc-400 dark:hover:bg-zinc-900 dark:hover:text-zinc-200"
      >
        <SearchIcon className="h-4 w-4" aria-hidden />
        <span className="hidden sm:inline">{strings.button}</span>
        <kbd className="ml-auto hidden rounded border border-zinc-200 bg-zinc-50 px-1.5 py-0.5 text-[10px] font-medium text-zinc-400 sm:inline dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-500">
          {strings.shortcutHint}
        </kbd>
      </button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-start justify-center p-4 pt-[10vh]">
          <div
            className="anim-fade absolute inset-0 bg-zinc-950/50 backdrop-blur-sm"
            onClick={close}
            aria-hidden
          />
          <div
            ref={dialogRef}
            role="dialog"
            aria-modal="true"
            aria-label={strings.dialogLabel}
            className="anim-pop relative w-full max-w-xl rounded-xl border border-zinc-200 bg-white p-4 shadow-2xl dark:border-zinc-800 dark:bg-zinc-950"
          >
            <div className="mb-3 flex items-center justify-between">
              <span className="text-sm font-medium text-zinc-500 dark:text-zinc-400">
                {strings.dialogLabel}
              </span>
              <button
                type="button"
                onClick={close}
                aria-label={strings.close}
                className="inline-flex h-7 w-7 items-center justify-center rounded-md text-zinc-500 transition-colors hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-900 dark:hover:text-zinc-100"
              >
                <X className="h-4 w-4" aria-hidden />
              </button>
            </div>

            {status === 'unavailable' ? (
              <p className="py-6 text-sm text-zinc-500 dark:text-zinc-400">
                {strings.unavailable}
              </p>
            ) : (
              <>
                {status === 'loading' && (
                  <p className="py-6 text-sm text-zinc-500 dark:text-zinc-400">
                    {strings.loading}
                  </p>
                )}
                <div ref={pagefindRef} />
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
}
