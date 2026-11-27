import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { cache } from 'react';
import matter from 'gray-matter';
import GithubSlugger from 'github-slugger';
import { toString } from 'mdast-util-to-string';
import remarkGfm from 'remark-gfm';
import remarkParse from 'remark-parse';
import { unified } from 'unified';
import { visit } from 'unist-util-visit';
import type { Heading, Root } from 'mdast';
import { locales, type Locale } from './i18n';

/**
 * Content contract (see AUTHORING.md):
 *   content/<lang>/index.md            → suite home   (/<lang>)
 *   content/<lang>/<app>/index.md      → app home     (/<lang>/<app>)
 *   content/<lang>/<app>/<slug>.md     → doc page     (/<lang>/<app>/<slug>)
 *
 * Frontmatter: title (required), description (required), section
 * ("User Guide" | "Developer Guide", omitted for homes), order (number).
 *
 * All reads happen at build time (static export) and are deduped with
 * React.cache. Missing files return null so pages can fall back gracefully
 * while content is being written in parallel.
 */

export const SECTIONS = ['User Guide', 'Developer Guide'] as const;
export type Section = (typeof SECTIONS)[number];

/** Fixed app order in the sidebar; unknown apps follow alphabetically. */
const APP_ORDER = ['zephyrus', 'eros', 'psyche', 'morpheus'];

export interface DocMeta {
  lang: Locale;
  /** Path relative to content/<lang>/, e.g. "zephyrus/configuration.md". */
  contentPath: string;
  /** Route slug segments; [] for the suite home, ['zephyrus'] for an app home. */
  slug: string[];
  /** Absolute URL path, e.g. "/en/zephyrus/configuration". */
  url: string;
  title: string;
  description: string;
  section?: Section;
  order: number;
  /** App directory name; null for the suite home. */
  app: string | null;
}

export interface TocItem {
  id: string;
  text: string;
  depth: 2 | 3;
}

export interface Doc extends DocMeta {
  body: string;
  toc: TocItem[];
}

export interface SidebarSection {
  label: Section;
  items: DocMeta[];
}

export interface SidebarApp {
  name: string;
  title: string;
  url: string;
  home: DocMeta | null;
  sections: SidebarSection[];
  /** Pages without a `section` in frontmatter, listed directly under the app. */
  ungrouped: DocMeta[];
}

export interface Sidebar {
  home: DocMeta | null;
  apps: SidebarApp[];
}

const CONTENT_ROOT = path.join(process.cwd(), 'content');

export function urlFor(lang: Locale, slug: string[]): string {
  return slug.length > 0 ? `/${lang}/${slug.join('/')}` : `/${lang}`;
}

/** content/<lang>/ relative path → route slug segments (index.md → parent). */
function slugFor(contentPath: string): string[] {
  const parts = contentPath.replace(/\.md$/i, '').split('/');
  if (parts[parts.length - 1] === 'index') parts.pop();
  return parts;
}

function titleize(value: string): string {
  return value
    .split(/[-_]/)
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

/** Recursively list .md files under a directory, as relative POSIX paths. */
function walk(dir: string, base = ''): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      out.push(...walk(path.join(dir, entry.name), rel));
    } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.md')) {
      out.push(rel);
    }
  }
  return out;
}

interface ParsedFile {
  meta: DocMeta;
  body: string;
}

/** Read + parse one content file. Tolerant of missing/partial frontmatter. */
const loadFile = cache(
  (lang: Locale, contentPath: string): ParsedFile | null => {
    const file = path.join(CONTENT_ROOT, lang, contentPath);
    let raw: string;
    try {
      raw = readFileSync(file, 'utf8');
    } catch {
      return null;
    }

    let data: Record<string, unknown> = {};
    let body = raw;
    try {
      const parsed = matter(raw);
      data = parsed.data as Record<string, unknown>;
      body = parsed.content;
    } catch {
      console.warn(
        `[content] invalid frontmatter in ${lang}/${contentPath}; using defaults`,
      );
    }

    const slug = slugFor(contentPath);
    const app = slug.length > 0 ? slug[0] : null;
    const fallbackTitle =
      slug.length === 0 ? 'Overview' : titleize(slug[slug.length - 1]);
    const title =
      typeof data.title === 'string' && data.title.trim() !== ''
        ? data.title.trim()
        : fallbackTitle;
    const description =
      typeof data.description === 'string' ? data.description.trim() : '';
    if (
      typeof data.title !== 'string' ||
      typeof data.description !== 'string'
    ) {
      console.warn(
        `[content] ${lang}/${contentPath}: frontmatter should define "title" and "description" (see AUTHORING.md)`,
      );
    }
    const section = SECTIONS.includes(data.section as Section)
      ? (data.section as Section)
      : undefined;
    const order =
      typeof data.order === 'number' && Number.isFinite(data.order)
        ? data.order
        : 999;

    return {
      meta: {
        lang,
        contentPath,
        slug,
        url: urlFor(lang, slug),
        title,
        description,
        section,
        order,
        app,
      },
      body,
    };
  },
);

/** Metadata for every content file of a locale, deduped by URL. */
export const getAllDocs = cache((lang: Locale): DocMeta[] => {
  const byUrl = new Map<string, DocMeta>();
  for (const contentPath of walk(path.join(CONTENT_ROOT, lang))) {
    const parsed = loadFile(lang, contentPath);
    if (!parsed) continue;
    const existing = byUrl.get(parsed.meta.url);
    // Prefer index.md over a sibling <name>.md if both map to the same URL.
    if (!existing || contentPath.endsWith('index.md')) {
      byUrl.set(parsed.meta.url, parsed.meta);
    }
  }
  return [...byUrl.values()];
});

/**
 * Extract h2/h3 headings; ids match rehype-slug (same github-slugger).
 * A leading body H1 is stripped: the page header renders the canonical
 * frontmatter title, so content may start with either `# Title` or prose.
 */
function processBody(markdown: string): { body: string; toc: TocItem[] } {
  const tree = unified()
    .use(remarkParse)
    .use(remarkGfm)
    .parse(markdown) as Root;
  let body = markdown;
  const first = tree.children[0];
  if (
    first &&
    first.type === 'heading' &&
    first.depth === 1 &&
    first.position
  ) {
    body = markdown.slice(first.position.end.offset).replace(/^\s+/, '');
    tree.children.shift();
  }
  const slugger = new GithubSlugger();
  const items: TocItem[] = [];
  visit(tree, 'heading', (node: Heading) => {
    const text = toString(node);
    const id = slugger.slug(text);
    if (node.depth === 2 || node.depth === 3) {
      items.push({ id, text, depth: node.depth });
    }
  });
  return { body, toc: items };
}

/**
 * Load one document by route slug. `[]` → suite home, `['zephyrus']` →
 * zephyrus/index.md, `['zephyrus', 'configuration']` → zephyrus/configuration.md.
 * Returns null when the file does not exist (callers fall back or 404).
 */
export const getDoc = cache((lang: Locale, slug: string[]): Doc | null => {
  const base = slug.join('/');
  const candidates =
    slug.length > 0 ? [`${base}/index.md`, `${base}.md`] : ['index.md'];
  const contentPath = candidates.find((candidate) =>
    existsSync(path.join(CONTENT_ROOT, lang, candidate)),
  );
  if (!contentPath) return null;

  const parsed = loadFile(lang, contentPath);
  if (!parsed) return null;
  const { body, toc } = processBody(parsed.body);
  return { ...parsed.meta, body, toc };
});

const byOrder = (a: DocMeta, b: DocMeta): number =>
  a.order - b.order || a.title.localeCompare(b.title);

/** Sidebar tree: suite home, apps in fixed order, sections sorted by order. */
export const getSidebar = cache((lang: Locale): Sidebar => {
  const docs = getAllDocs(lang);
  const home = docs.find((doc) => doc.slug.length === 0) ?? null;

  const names = [
    ...new Set(
      docs.map((doc) => doc.app).filter((a): a is string => a !== null),
    ),
  ];
  names.sort((a, b) => {
    const ia = APP_ORDER.indexOf(a);
    const ib = APP_ORDER.indexOf(b);
    if (ia !== -1 && ib !== -1) return ia - ib;
    if (ia !== -1) return -1;
    if (ib !== -1) return 1;
    return a.localeCompare(b);
  });

  const apps: SidebarApp[] = names.map((name) => {
    const appDocs = docs.filter((doc) => doc.app === name);
    const appHome = appDocs.find((doc) => doc.slug.length === 1) ?? null;
    const pages = appDocs.filter((doc) => doc.slug.length > 1);
    const sections = SECTIONS.map((label) => ({
      label,
      items: pages.filter((page) => page.section === label).sort(byOrder),
    })).filter((section) => section.items.length > 0);
    return {
      name,
      title: appHome?.title ?? titleize(name),
      url: urlFor(lang, [name]),
      home: appHome,
      sections,
      ungrouped: pages.filter((page) => !page.section).sort(byOrder),
    };
  });

  return { home, apps };
});

/** Flattened reading order: suite home, then per app home → sections. */
export const getFlatOrder = cache((lang: Locale): DocMeta[] => {
  const sidebar = getSidebar(lang);
  const flat: DocMeta[] = [];
  if (sidebar.home) flat.push(sidebar.home);
  for (const app of sidebar.apps) {
    if (app.home) flat.push(app.home);
    for (const section of app.sections) flat.push(...section.items);
    flat.push(...app.ungrouped);
  }
  return flat;
});

/** Previous/next documents across the flattened reading order. */
export function getAdjacent(
  lang: Locale,
  url: string,
): { prev: DocMeta | null; next: DocMeta | null } {
  const flat = getFlatOrder(lang);
  const index = flat.findIndex((doc) => doc.url === url);
  if (index === -1) return { prev: null, next: null };
  return {
    prev: flat[index - 1] ?? null,
    next: flat[index + 1] ?? null,
  };
}

/** All { lang, slug } params for app/[lang]/[...slug]/generateStaticParams. */
export function getAllDocParams(): { lang: Locale; slug: string[] }[] {
  return locales.flatMap((lang) =>
    getAllDocs(lang)
      .filter((doc) => doc.slug.length > 0)
      .map((doc) => ({ lang, slug: doc.slug })),
  );
}
