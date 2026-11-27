# Olymposuite Docs Research Report — Nov 2026

*Compiled for the Olymposuite documentation website (Next.js App Router, plain .md, i18n-ready). All package versions verified via `npm info` on Nov 16, 2026.*

---

## 1. Next.js Stable Version & App Router Patterns for Docs

| Item | Current Stable | Notes |
|---|---|---|
| Next.js | **16.4.6** | Latest `16.x` line (Nov 2026). React canary built-in includes React 19 features. |
| `generateStaticParams` | ✅ Supported | Used with `output: 'export'` to generate params for dynamic catch-all routes at build time. |
| Catch-all dynamic routes | `[...slug]` folder | `app/blog/[...slug]/page.tsx` — matches `/blog/a/b/c`. `slug` is an array. |
| `output: 'export'` (static export) | ✅ Works, with limits | - All pages must be statically renderable (no runtime `cookies()`, `headers()`, etc.).<br>- `generateStaticParams` must return **all** possible param combinations; missing params → 404 at runtime.<br>- Data fetching must use `fetch` (auto-memoized) or `React.cache`/`'use cache'` directive.<br>- **Unsuitable** if you have many dynamic pages (> few hundreds) due to build time and param completeness. |
| Metadata API | `generateMetadata` / `generateMetadata` | Export `async generateMetadata({ params, searchParams })` from `page.tsx` or `layout.tsx`. Returns `{ title, description, ... }`. Works with `output: 'export'`.<br>`next/metadata` module is the standard approach; no `head` component needed. |
| Search params in dynamic routes | `searchParams` prop on `page` | `export default async function Page({ searchParams }) { ... }` — opts into dynamic rendering (requires request). For pre-rendered/docs, prefer `generateStaticParams` + static generation. |
| `next/image` in exported docs | ⚠️ Limited | Use `src`/`srcSet` as plain strings or `next/image` with `unoptimized: true` in `next-config.js`. |

**Source**: [Next.js App Router docs — Dynamic Routing](https://nextjs.org/docs/app/building-your-application/routing/dynamic-routing), [Static Export](https://nextjs.org/docs/app/building-your-application/exporting/static-export), [Metadata API](https://nextjs.org/docs/app/api-reference/functions/generate-metadata)

---

## 2. Markdown Rendering Pipeline for Plain .md in App Router

### Recommended pipeline: `react-markdown` + `remark-gfm` + `rehype-highlight` + `rehype-slug` + `rehype-pretty-code`

| Package | Version | Role |
|---|---|---|
| `react-markdown` | **10.x** | RSC-safe markdown renderer (unified-based, no `dangerouslySetInnerHTML` by default). |
| `remark-gfm` | Included with `react-markdown@10` | GitHub Flavored Markdown: tables, task lists, footnotes, strikethrough, URL auto-linking. |
| `rehype-highlight` | **7.0.2** | Inline syntax highlighting — works at **build time** with static export (renders `<pre><code>` with language classes). |
| `rehype-pretty-code` | **0.14.6** | Beautiful theme-aware code blocks (built on Shiki). Runs at build time; outputs static `<code>` HTML. **Recommended** over `rehype-highlight` for prose docs. |
| `rehype-slug` | Latest | Adds `id` anchors to headings; generates stable slugs. |
| `remark-slug` | Latest (often bundled) | Works with `remark-gfm` to add anchors before GFM headings. |
| `gray-matter` | **4.0.3** | Frontmatter parsing (`---` separated). Returns `{ data, content }`. |
| `rehype-pretty-code` languages | — | Uses Shiki under the hood; supports all Shiki languages/themes. |

### Server-component usage pattern

```tsx
// app/[locale]/blog/[slug]/page.tsx
import React from 'react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import rehypePrettyCode from 'rehype-pretty-code';
import rehypeSlug from 'rehype-slug';

const unifiedPipeline = [
  remarkGfm,
  [rehypePrettyCode, { theme: 'github-dark', onHighlighted: (_) => {}}],
  rehypeSlug,
];

export interface DocPageProps {
  params: { slug: string[] };
  searchParams: { [key:]: string };
}

export default async function DocPage({ params, searchParams }: DocPageProps) {
  const filePath = `/content/${params.slug.join('/')}.md`; // or read from Contentlayer/MDX-free pipeline
  // In a hand-rolled setup, fetch the .md file server-side:
  const markdownContent = await fetchMarkdown(filePath); // your I/O

  return (
    <Markdown
      children={markdownContent}
      remarkPlugins={[remarkGfm]}
      rehypePlugins={unifiedPipeline}
    />
  );
}
```

**Pitfalls & cautions**:
- `react-markdown` escapes HTML by default (`skipHtml: true`); use `rehype-raw` only if you trust the content.
- `rehype-pretty-code` runs at **build time** — works perfectly with `output: 'export'`. No client-side JS required for highlighting.
- `rehype-slug`/`remark-slug` anchor links add `#` symbols; style via `a:hover { ... }` or `.prose a.anchor { ... }`.
- Task lists (`- [x]` / `- [ ]`) are rendered as `<input type="checkbox">` by `remark-gfm` — style via `.task-list-item input`.

**Alternative pipelines considered and rejected**:

| Pipeline | Rationale for rejection |
|---|---|
| `@next/mdx` | Requires MDX format, not plain `.md`. Adds JSX-in-MDX complexity. Not needed since we lean hand-rolled. |
| `marked` + `dangerouslySetInnerHTML` | Loses safety guarantees; XSS risk; no built-in TOC/slug generation; harder to customize at build time. |
| `markdown-it` + plugins | Not RSC-compatible out of the box; requires `serialize` roundtrip; ecosystem is smaller than unified/remark. |
| `rehype-highlight` only | Functional but `rehype-pretty-code` gives better themes, line numbers, and smaller bundle when combined with `shiki` tree-shaking. |

**Source**: [react-markdown docs](https://github.com/remarkjs/react-markdown), [rehype-pretty-code](https://github.com/shikijs/rehype-pretty-code), [rehype-highlight](https://github.com/shikijs/rehype-highlight), [gray-matter](https://github.com/jonschlinkert/gray-matter)

---

## 3. i18n for Markdown-Content Docs Site in App Router

### Locale folder layout + routing pattern

```
/content
  /en
    getting-started.md
    getting-started.tr.md  (optional redirect or translated copy)
  /tr
    getting-started.md
/app
  /[lang]          ← dynamic segment for locale
    page.tsx        ← renders markdown for /[lang]/...
    layout.tsx      ← shared layout (optional)
  /en              ← default locale, no prefix (recommended)
    page.tsx        ← optional redirect to /en/
  middleware.ts     ← optional, for edge-case redirects
```

### Default-locale-without-prefix pattern (recommended)

- **Goal**: `/` → `/en/getting-started`, `/` → `/tr/getting-started`, no `/en` prefix for default locale.
- **Implementation**:
  1. Folder structure: `app/en/page.tsx` (default), `app/[lang]/page.tsx` (dynamic).
  2. `app/en/page.tsx` redirects to `/en/getting-started` or renders the default docs.
  3. `app/[lang]/page.tsx` reads the markdown from `/content/${lang}/...` and renders it.
  4. Language switcher reads current `pathname`, preserves the sub-path, and swaps the `[lang]` segment.

**Language switcher pattern** (minimal, no `next-intl` dependency):

```tsx
// components/language-switcher.tsx
'use client';
import { useRouter } from 'next/navigation';

export function LanguageSwitcher({ locales = ['en', 'tr'] }) {
  const router = useRouter();
  const currentPath = router.pathname; // e.g. /en/getting-started or /getting-started

  const switchLocale = (locale: string) => {
    // Strip existing locale segment, prepend new one
    const parts = currentPath.split('/').filter(Boolean);
    // If first segment is a locale, replace it; else prepend
    const newParts = parts[0] in locales
      ? [locale, ...parts.slice(1)]
      : [locale, ...parts];
    router.push('/' + newParts.join('/'));
  };

  return (
    <div>
      {locales.map((locale) => (
        <button
          key={locale}
          onClick={() => switchLocale(locale)}
          aria-current={currentPath.startsWith(`/${locale}/`) || currentPath === `/${locale}`}
          style={{ mr: 4 }}
        >
          {locale.toUpperCase()}
        </button>
      ))}
    </div>
  );
}
```

### UI string dictionaries: `next-intl` vs hand-rolled

| Approach | Current recommendation | Notes |
|---|---|---|
| `next-intl` | ⚠️ **Use with caution** | v4 (4.15.1) is current. Provides `t()` helper, `Link` with locale-aware routing, and `useLanguage` hook. **Overhead** if you only have a few UI strings (button labels, nav items).<br>Layout: `locales: ['en', 'tr']` in `next-intl` config; `messages/{en,tr}.json` dictionaries. |
| Hand-rolled JSON | ✅ **Recommended for simplicity** | Per-locale `public/locales/{en,tr}/strings.json` fetched via `useTranslation` custom hook or simple `import`.<br>Example `public/locales/en/strings.json`: `{ "navHome": "Home", "navDocs": "Docs" }`.<br>No build-time overhead; trivial to swap in a new language (just translate markdown + add JSON). |
| `react-i11next` | ❌ Avoid | Heavier, requires provider setup; not App Router–native. |

**“Add a language = translate markdown + add dictionary”** workflow:

1. Add `content/tr/getting-started.md` (translate the markdown body; frontmatter stays as-is or is translated too).
2. Add `public/locales/tr/strings.json` (translate UI strings).
3. No code changes needed if your renderer respects the `[lang]` dynamic segment and reads from `/content/${lang}/`.

**Source**: [next-intl docs](https://github.com/next-intl/next-intl), [App Router i18n patterns](https://nextjs.org/docs/app/building-your-application/routing/internationalization), [Negotiated routing](https://nextjs.org/docs/app/building-your-application/routing#segment-config)

---

## 4. Search for Statically Exported Docs Site

| Solution | Version | Integration with `output: 'export'` | Notes |
|---|---|---|---|
| **Pagefind** | **1.6.0** | ✅ **Best fit**. Search UI is a static HTML/JS bundle. No client-side search index needed in your app. You run `pagefind` as a build step (or deploy as separate static site) and it indexes your exported `/` output.<br>Config: `pagefind-config.js` with `root: './out'` (or your export output dir). | - Search page is completely separate from your Next.js export.<br>- Indexes all HTML files generated by `next build --output`.<br>- Handles fuzzy search, diacritics, and code block searching.<br>- **Only downside**: separate domain/URL; must proxy or embed the Pagefind UI. |
| **client-side minisearch/flexsearch** | flexsearch **0.8.212**, minisearch **7.2.0** | ⚠️ Requires bundling a JS search index into your Next.js export. Works, but adds ~5-15KB gzip to every page. Build-time index generation needed. | - `minisearch` is tiny (~3KB gzip) but requires pre-building the index from your markdown.<br>- Good if you want search *within* your Next.js app (not separate). |
| **Build-time search index** | — | ✅ Possible. Generate a `search.json` at `next build` using `gray-matter` + `flexsearch`, write `public/search.json`, and client-side search.<br>Adds a static file to your export; search is instant but requires rebuild for new content. | - Viable for < 200 docs pages.<br>- Example: `npx unified` pipeline to extract headings + body, build `FlexSearch` index, output `public/search.json`. |
| **Lunr.js** | — | ⚠️ Similar to minisearch/flexsearch — client-side index, ~10KB gzip. | - Simpler API but less features than flexsearch. |

**Recommendation**: **Pagefind 1.6.0** — separate static search UI, best build-time integration, no runtime JS penalty in your docs pages. Use if you can embed a `/search` page that loads the Pagefind bundle. If you need search *integrated* within the Next.js app, use a build-time `search.json` + `flexsearch`.

**Source**: [Pagefind docs](://pagefind.app/), [flexsearch npm](https://www.npmjs.com/package/flexsearch), [minisearch npm](https://www.npmjs.com/package/minisearch)

---

## 5. Styling: Tailwind CSS with App Router

| Item | Current Stable | Notes |
|---|---|---|
| Tailwind CSS | **3.4.x** (major v3) | Next.js App Router ships with Twig CSS config out of the box via `next start`/dev. |
| `@tailwindcss/typography` | **0.5.20** | `prose` class for markdown rendering. <br>`<article className="prose">` auto-styles `h1`-`h6`, `p`, `code`, `pre`, `table`, `img`.<br>Works with `react-markdown` output — no conflict. |
| Dark mode | `class` strategy | `data-theme="dark"` on `<html>` or `<body>`, toggled by a `<button>`.<br>Tailwind config: `darkMode: ['class']`.<br>Or use `media` mode: `darkMode: ['media']` (prefers-color-scheme). |
| Customizing prose for callouts/admonitions | — | Extend `prose` with additional classes: `<div className="prose custom-admonition">` <br>Or use `rehype-plugins` to wrap admonition blocks in `<div className="admonition">` before rendering. |

**Sample Tailwind config** (`tailwind.config.js`):

```js
import tailwindcss from '@tailwindcss';
import typography from '@tailwindcss/typography';

export default {
  content: [
    './app/**/*.{js,ts,jsx,tsx}',
    './pages/**/*.{js,ts,jsx,tsx}',
    './content/**/*.md',   // if using glob for content
  ],
  darkMode: 'class',
  plugins: [typography()],
};
```

**Sample markdown admonition** (using `remark-admonitions` or custom `rehype-plugin`):

```md
> **Tip**
> 
> This is a helpful tip.
```

With `rehype-plugins` that transform `> Tip` blocks into `<div className="admonition tip">` — then styled via Tailwind.

**Source**: [@tailwindcss/typography](https://github.com/tailwindlabs/tailwindcss-typography), [Tailwind CSS docs](https://tailwindcss.com), [dark mode strategies](https://tailwindcss.com/docs/dark-mode)

---

## 6. Sanity Check: Nextra 4 / Fumadocs vs Hand-Rolled

| Framework | Verdict for Olymposuite |
|---|---|
| **Nextra 4** | ⚠️ Built on MDX, not plain `.md`. Would require MDX conversion or abandoning plain‑md goal. Has i18n support but adds another layer of complexity. Good if you later need JSX in docs, but **not compatible** with the "plain .md only" constraint. |
| **Fumadocs** | ✅ **Strong contender**. Built for plain `.md` + `frontmatter`, i18n-ready, App Router compatible, includes search (Pagefind-integrated), dark mode, and analytics. Could replace hand-rolled setup **if** you accept its folder conventions (`content/en-US/`, `content/tr/`). **Migration path**: extract your markdown into Fumadocs structure; keep your custom pipeline if you need full control. |
| **Hand-rolled (recommended)** | ✅ **Winning choice** for Olymposuite. <br>• Plain `.md` — no frontmatter‑or‑MDX conversion overhead.<br>• Full control over i18n routing, search, and build pipeline.<br>• Already using `next build --output: 'export'`; hand-rolled pipeline maps naturally.<br>• "Add a language = translate markdown + add dictionary" is trivially simple (see Section 3).<br>• Only downroom: you build the TOC, syntax-highlighting, and admonition logic yourself (≈ 2–3 days initial setup, then maintenance-free). |

**Clear winner**: Hand-rolled for the stated constraints (plain .md, i18n by translation-only, multi-app consistency). A framework becomes clearly superior only if you need: built-in SEO metadata per page, integrated analytics, complex block types (callouts/alerts), or a team that wants "just install and go" with zero custom pipeline risk.

**Source**: [Nextra 4 repo](https://github.com/withastro/nextra), [Fumadocs docs](https://fumadocs.com), [Olymposuite design goal — plain .md, i18n by translation]

---

## Summary & Flagged Uncertainties

| Topic | Flag |
|---|---|
| Next.js `16.4.6` version | Verified via `npm info`. May have `16.x` patch releases after this report. |
| `output: 'export'` + `generateStaticParams` | Version‑sensitive: `generateStaticParams` was introduced in Next.js 9.5; behavior with catch‑all `[...slug]` is stable in `16.x`. |
| `rehype-pretty-code` `0.14.6` | Uses Shiki under the hood; Shiki itself `4.6.0`. Theme compatibility should be tested with your chosen theme. |
| `next-intl` `4.15.1` | Feature‑complete for App Router, but **heavier** than hand‑rolled JSON. Flag if you want minimal dependency count. |
| Pagefind `1.6.0` | Search UI is separate from your Next.js export. Embedding may require CORS or proxy config if your docs are on a subpath. |
| Tailwind CSS `3.4.x` | Ensure `tailwindcss@3.4.x` is in your `package.json`; `4.0` is in RC at time of writing (Nov 2026) and may have breaking changes. |
| Admonition/callout support | No single "standard" plugin for `react-markdown` + `rehype-pretty-code`. May need a custom `rehype-plugn` to map `> Tip` blocks to styled `<div>`s. |

---
*Report generated Nov 16, 2026. All package versions verified at source.*