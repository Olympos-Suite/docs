# Authoring Guide — Olymposuite Documentation

This repository is the documentation website for the Olymposuite suite
(Zephyrus, Eros, Psyche, Morpheus). It is a hand-rolled **Next.js 16 App
Router** site, statically exported (`output: 'export'`), rendering plain
`.md` files with `react-markdown`. No MDX, no CMS, no middleware.

**Suite standard:** Node >= 24, pnpm 12. This repo was built with
Node 24 / pnpm 12.7.0.

---

## Commands

```sh
pnpm install      # install dependencies
pnpm dev          # dev server (search shows a "available after build" note)
pnpm build        # static export to out/  →  postbuild runs Pagefind automatically
pnpm typecheck    # tsc --noEmit (strict)
pnpm lint         # ESLint 9 flat config
pnpm format       # Prettier 3 (content/ and notes/ are excluded)
pnpm test         # node --test: unit tests for the alert plugin + link resolver
```

Serve the production output locally:

```sh
pnpm build
python3 -m http.server 8899 --directory out   # or: npx serve out
```

> **Pagefind version note:** `pagefind` is pinned to **~1.4.0** on purpose.
> Pagefind >= 1.5 ships binaries that execute AVX instructions; the suite's
> build host is a QEMU virtual CPU without AVX and crashes with SIGILL.
> 1.4.0 works everywhere. Do not bump it without verifying on the build host.

---

## Content layout

```
content/
  en/                     ← one directory per locale (currently only en)
    index.md              ← suite home          → /en/  (and /)
    zephyrus/
      index.md            ← app home            → /en/zephyrus/
      installation.md     ← doc page            → /en/zephyrus/installation/
      configuration.md    ← doc page            → /en/zephyrus/configuration/
    eros/
      index.md
    psyche/
      index.md
    morpheus/
      index.md
locales/
  en.json                 ← UI strings (header, search, nav labels, …)
```

Rules:

- One `.md` file per page. The URL is `/<lang>/<app>/<slug>` where `<slug>` is
  the file name without `.md`.
- `index.md` always maps to its **parent** path: `content/en/index.md` → `/en/`,
  `content/en/eros/index.md` → `/en/eros/`.
- The root URL `/` renders the default-locale (`en`) suite home.
- App directories are plain folders; nesting deeper than `<app>/<slug>.md`
  works mechanically but is not part of the contract — keep it flat.
- Files are read at **build time** only. Adding or editing content requires a
  rebuild; there is no runtime filesystem access.

## Frontmatter schema

Every file starts with YAML frontmatter:

```yaml
---
title: Smart Queuing # REQUIRED — sidebar, <h1>, <title>, search
description: One sentence. # REQUIRED — lead paragraph + meta description
section: User Guide # "User Guide" | "Developer Guide"
order: 30 # number, sorts within its section
---
```

- `section` is **omitted** for the suite home and app homes. Pages without a
  section appear directly under their app in the sidebar (avoid this).
- `order` sorts ascending within a section; ties break alphabetically by
  title. App homes use `order: 0`. Convention: leave gaps (10, 20, 30 …) so
  pages can be inserted later.
- Missing `title`/`description` does not crash the build (a fallback title is
  derived from the file name and a warning is logged) — but they are required
  by the contract; always provide them.

## Body conventions

- The page header renders `title` and `description` from frontmatter. Start
  the body with prose or `##` sections. A leading `# H1` in the body is
  tolerated and stripped (the frontmatter title wins) — prefer not adding it.
- The right-rail **table of contents** is generated from `##` and `###`
  headings. Heading ids are GitHub-style slugs (rehype-slug); duplicate
  headings get `-1`, `-2` suffixes.
- Code blocks are highlighted at build time by shiki via `rehype-pretty-code`
  with dual themes (`github-light` / `github-dark`), switched by the `.dark`
  class. Always tag the language: ` ```yaml `, ` ```bash `, ` ```ts `.
- GFM is enabled: tables (wrapped in a horizontal-scroll container), task
  lists (`- [x]`), strikethrough, footnotes, autolinks.
- Raw HTML in markdown is **not** rendered (react-markdown escapes it).

### GitHub-style alerts

```md
> [!NOTE]
> Useful information.

> [!TIP]
> Optional advice.

> [!IMPORTANT]
> Key information.

> [!WARNING]
> Needs attention.

> [!CAUTION]
> Risky action.
```

Markers must be uppercase and on their own line (as on GitHub). They render
as styled callout divs (`lib/github-alerts.ts`, unit-tested).

## Links — the relative-link rule

**All internal links are relative to the current file**, exactly as they
would resolve on the filesystem:

| From                        | Write                    | Resolves to                          |
| --------------------------- | ------------------------ | ------------------------------------ |
| `zephyrus/index.md`         | `./configuration`        | `/en/zephyrus/configuration/`        |
| `zephyrus/configuration.md` | `./smart-queuing#limits` | `/en/zephyrus/smart-queuing/#limits` |
| `zephyrus/configuration.md` | `../eros/`               | `/en/eros/`                          |
| `zephyrus/configuration.md` | `../`                    | `/en/` (suite home)                  |
| any                         | `./other.md`             | `.md` is stripped                    |

The custom `a` renderer (`components/markdown.tsx` + `lib/links.ts`) resolves
these against the document's content path and **preserves the locale**, so
translated pages link within their own language automatically.

- External links (`https:`, `mailto:`, any scheme) open in a new tab with
  `rel="noopener noreferrer"` — write them as normal absolute URLs.
- Pure fragments (`#section`) and site-absolute paths (`/en/...`) pass through
  untouched; prefer relative links.

## Sidebar and reading order

Auto-generated from the content tree at build time (`lib/content.ts`):

1. Suite home (`content/<lang>/index.md`).
2. Apps in fixed order: **zephyrus, eros, psyche, morpheus** (any unknown app
   directories follow alphabetically).
3. Within an app: app home, then **User Guide** pages, then **Developer
   Guide** pages, each sorted by `order`.

Prev/next footer links follow the same flattened order across apps.

---

## How to add a new app

1. Create `content/en/<app>/index.md` with frontmatter (`title`,
   `description`, `order: 0`, no `section`) and an intro paragraph.
2. Add doc pages `content/en/<app>/<slug>.md` with `section` + `order`.
3. If the app should appear in the fixed sidebar order, add its name to
   `APP_ORDER` in `lib/content.ts` (otherwise it sorts alphabetically after
   the known apps).
4. Rebuild. Sidebar, routes, prev/next, and search pick everything up
   automatically.

## How to add a language

Exactly three steps — **no other code changes**:

1. Add the locale code to `locales` in `lib/i18n.ts`
   (e.g. `['en', 'tr'] as const`).
2. Mirror the content tree: `content/tr/…` (translate bodies and frontmatter;
   keep file names, `section` values, and `order` identical to `en`).
3. Add `locales/tr.json` — copy `locales/en.json` and translate the values
   (keep the keys; TypeScript enforces the shape against `en.json`).

The language switcher in the header activates automatically (it renders
disabled while only one locale exists) and swaps the first path segment,
preserving the current page. `section` stays the English enum in frontmatter;
its display label is translated via the dictionary (`nav.userGuide`,
`nav.developerGuide`).

---

## Architecture map

```
app/
  layout.tsx                  root <html>/<body>, theme bootstrap script, metadata
  page.tsx                    / → en suite home
  not-found.tsx               404 page
  icon.svg                    favicon
  globals.css                 Tailwind v4 CSS-first config + callout/shiki/pagefind styles
  [lang]/
    layout.tsx                validates lang against locales (404 otherwise), site shell
    page.tsx                  /<lang>/ locale home
    [...slug]/page.tsx        /<lang>/<app>/<slug> doc pages; generateStaticParams
                              enumerates ALL content files; dynamicParams = false
components/
  site-shell.tsx              header + sidebar + main grid (server)
  site-header.tsx             wordmark, search, theme, language, mobile drawer (client)
  sidebar-nav.tsx             nav tree with active-link highlighting (client)
  doc-content.tsx             article: breadcrumb, title, prose, prev/next, TOC rail
  markdown.tsx                MarkdownAsync + plugins + custom a/table renderers
  toc.tsx                     right rail, IntersectionObserver scroll-spy (client)
  search.tsx                  Pagefind modal, loads /pagefind/ bundle at runtime
  theme-toggle.tsx            class toggle + localStorage
  language-switcher.tsx       usePathname-based locale swap
  prev-next.tsx               pager footer
lib/
  i18n.ts                     locales / defaultLocale / isLocale
  dictionary.ts               server-readable locales/<lang>.json (fs, build time)
  content.ts                  loader: getDoc / getSidebar / getFlatOrder / getAdjacent /
                              getAllDocParams; gray-matter + TOC extraction; React.cache
  links.ts                    relative-href resolver (unit-tested)
  github-alerts.ts            remark plugin for > [!NOTE] callouts (unit-tested)
```

Key decisions:

- **Tailwind CSS v4, CSS-first config**: `@import 'tailwindcss'` +
  `@plugin '@tailwindcss/typography'` + `@custom-variant dark` in
  `app/globals.css`; `@tailwindcss/postcss` in `postcss.config.mjs`.
  There is no `tailwind.config.js`.
- **No middleware** — incompatible with `output: 'export'`.
- **Theme**: `.dark` class on `<html>`, set pre-paint by an inline script:
  localStorage → `prefers-color-scheme` → **default dark**.
- **Search**: Pagefind indexes `out/` in `postbuild` (`pagefind --site out`);
  only `<article data-pagefind-body>` content is indexed. The modal loads
  `/pagefind/pagefind-ui.js` + `.css` at runtime (they are generated, not
  bundled). In `pnpm dev` the bundle does not exist → graceful fallback
  message. Ctrl/Cmd+K opens the modal.
- **Graceful fallback**: if `content/<lang>/index.md` is missing, the home
  page renders a static intro with app cards instead of crashing.
- `trailingSlash: true` — every route exports as `<path>/index.html`, so any
  dumb static file server works.

## Notes for the visual polish pass

- Styling baseline is intentionally plain (zinc palette, functional layout).
  All layout chrome lives in `components/site-shell.tsx` / `site-header.tsx`;
  prose styling is `prose prose-zinc dark:prose-invert` in `doc-content.tsx`
  plus overrides in `app/globals.css` (callouts, shiki, task lists, pagefind
  variables).
- Callout colors are plain CSS classes `.callout-note|tip|important|warning|
caution` in `globals.css` — restyle there, not in the plugin.
- The search modal inherits Pagefind UI's CSS variables (`--pagefind-ui-*`,
  set in `globals.css`); override them to match the final palette.
- Breakpoints: sidebar becomes a drawer below `lg` (1024px); TOC rail hides
  below `xl` (1280px).
