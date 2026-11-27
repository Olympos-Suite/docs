'use client';

import { Menu, Mountain, X } from 'lucide-react';
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { iconButtonClass } from '@/components/control-styles';
import { LanguageSwitcher } from '@/components/language-switcher';
import { Search } from '@/components/search';
import { ThemeToggle } from '@/components/theme-toggle';
import { useDialog } from '@/components/use-dialog';
import type { Dictionary } from '@/lib/dictionary';
import { locales, type Locale } from '@/lib/i18n';

/**
 * Sticky header + mobile navigation drawer. The drawer receives the
 * server-rendered sidebar nav as a ReactNode prop, so navigation data never
 * needs to be refetched on the client. It stays mounted (inert when closed) so
 * the slide transition runs in both directions; useDialog handles scroll lock,
 * Escape, the focus trap, and focus restoration.
 *
 * The header owns both dialog states (drawer + search) so opening one always
 * closes the other — there is never more than one active focus trap.
 */
export function SiteHeader({
  lang,
  dict,
  nav,
}: {
  lang: Locale;
  dict: Dictionary;
  nav: ReactNode;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const drawerRef = useRef<HTMLDivElement>(null);

  const closeMenu = useCallback(() => setMenuOpen(false), []);
  useDialog({ open: menuOpen, onClose: closeMenu, containerRef: drawerRef });

  const openMenu = useCallback(() => {
    setSearchOpen(false);
    setMenuOpen(true);
  }, []);

  const handleSearchChange = useCallback((next: boolean) => {
    if (next) setMenuOpen(false);
    setSearchOpen(next);
  }, []);

  // Ctrl/Cmd+K toggles search from anywhere (and dismisses the drawer).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        setMenuOpen(false);
        setSearchOpen((value) => !value);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  return (
    <>
      <header className="sticky top-0 z-40 border-b border-zinc-200 bg-white/85 backdrop-blur-md dark:border-zinc-800 dark:bg-zinc-950/85">
        <div className="mx-auto flex h-14 w-full max-w-[90rem] items-center gap-3 px-4">
          <button
            type="button"
            onClick={openMenu}
            aria-label={dict.nav.menu}
            aria-expanded={menuOpen}
            className={`${iconButtonClass} lg:hidden`}
          >
            <Menu className="h-4 w-4" aria-hidden />
          </button>

          <Link
            href="/"
            className="flex items-center gap-2 rounded-md font-semibold tracking-tight"
          >
            <Mountain className="h-5 w-5 text-accent" aria-hidden />
            {dict.site.title}
            <span className="hidden rounded-full border border-zinc-200 px-2 py-0.5 text-[11px] font-medium text-zinc-500 sm:inline dark:border-zinc-800 dark:text-zinc-400">
              {dict.site.tagline}
            </span>
          </Link>

          <div className="ml-auto flex items-center gap-2">
            <Search
              strings={dict.search}
              open={searchOpen}
              onOpenChange={handleSearchChange}
            />
            <ThemeToggle label={dict.theme.toggle} />
            <LanguageSwitcher
              locales={locales}
              current={lang}
              label={dict.language.label}
            />
          </div>
        </div>
      </header>

      <div
        className={`fixed inset-0 z-50 lg:hidden ${menuOpen ? '' : 'pointer-events-none'}`}
        aria-hidden={!menuOpen}
      >
        <div
          className={`absolute inset-0 bg-zinc-950/50 backdrop-blur-sm transition-opacity duration-200 ${
            menuOpen ? 'opacity-100' : 'opacity-0'
          }`}
          onClick={closeMenu}
          aria-hidden
        />
        <div
          ref={drawerRef}
          role="dialog"
          aria-modal="true"
          aria-label={dict.nav.documentation}
          inert={!menuOpen}
          className={`absolute inset-y-0 left-0 flex w-72 max-w-[85vw] flex-col border-r border-zinc-200 bg-white shadow-xl transition-transform duration-200 ease-out dark:border-zinc-800 dark:bg-zinc-950 ${
            menuOpen ? 'translate-x-0' : '-translate-x-full'
          }`}
        >
          <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
            <span className="text-sm font-semibold">
              {dict.nav.documentation}
            </span>
            <button
              type="button"
              onClick={closeMenu}
              aria-label={dict.nav.close}
              className={iconButtonClass}
            >
              <X className="h-4 w-4" aria-hidden />
            </button>
          </div>
          {/* Close the drawer when any navigation link inside it is clicked. */}
          <div
            className="flex-1 overflow-y-auto p-4"
            onClickCapture={(event) => {
              if ((event.target as HTMLElement).closest('a')) closeMenu();
            }}
          >
            {nav}
          </div>
        </div>
      </div>
    </>
  );
}
