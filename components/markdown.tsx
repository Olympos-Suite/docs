import Link from 'next/link';
import { MarkdownAsync, type Components } from 'react-markdown';
import rehypePrettyCode from 'rehype-pretty-code';
import rehypeSlug from 'rehype-slug';
import remarkGfm from 'remark-gfm';
import { remarkGithubAlerts } from '@/lib/github-alerts';
import type { Locale } from '@/lib/i18n';
import { resolveHref } from '@/lib/links';

/**
 * Build-time markdown renderer (async server component — rehype-pretty-code
 * highlights with shiki at build time, so the static export ships plain HTML).
 *
 * - GFM tables get a horizontal-scroll wrapper; task lists come from remark-gfm.
 * - rehype-slug adds heading anchors (ids match the TOC from lib/content.ts).
 * - Dual shiki themes are emitted as CSS variables; globals.css switches them
 *   with the `.dark` class.
 * - Relative links are resolved against the current document's content path
 *   (locale-preserving); external links open in a new tab.
 */
export function Markdown({
  body,
  lang,
  contentPath,
}: {
  body: string;
  lang: Locale;
  contentPath: string;
}) {
  const components: Components = {
    a({ node: _node, href, children, ...props }) {
      const resolved = resolveHref(href ?? '', contentPath, lang);
      if (resolved.external) {
        return (
          <a
            href={resolved.href}
            target="_blank"
            rel="noopener noreferrer"
            {...props}
          >
            {children}
          </a>
        );
      }
      return (
        <Link href={resolved.href} {...props}>
          {children}
        </Link>
      );
    },
    table({ node: _node, children, ...props }) {
      return (
        <div className="table-wrap overflow-x-auto">
          <table {...props}>{children}</table>
        </div>
      );
    },
  };

  return (
    <MarkdownAsync
      remarkPlugins={[remarkGfm, remarkGithubAlerts]}
      rehypePlugins={[
        rehypeSlug,
        [
          rehypePrettyCode,
          {
            theme: { light: 'github-light', dark: 'github-dark' },
            defaultColor: false,
          },
        ],
      ]}
      components={components}
    >
      {body}
    </MarkdownAsync>
  );
}
