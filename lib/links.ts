export interface ResolvedLink {
  href: string;
  external: boolean;
}

/** Any URI scheme (http:, https:, mailto:, tel:, ...) or protocol-relative URL. */
const EXTERNAL_RE = /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i;

/**
 * Resolve a markdown link href against the current document's content path.
 *
 * Content links are RELATIVE, e.g. `./configuration`, `../eros/`,
 * `./advanced#tuning`. They are resolved against the directory of the current
 * document inside `content/<lang>/` and turned into absolute, locale-preserving
 * site URLs (`/<lang>/...`). `index.md` maps to its parent path and a trailing
 * `.md` extension is stripped.
 *
 * @param href        raw href from the markdown source
 * @param contentPath document path relative to `content/<lang>/`,
 *                    e.g. `zephyrus/configuration.md` or `index.md`
 * @param locale      current locale (kept as the first URL segment)
 */
export function resolveHref(
  href: string,
  contentPath: string,
  locale: string,
): ResolvedLink {
  if (!href) return { href: '', external: false };
  if (EXTERNAL_RE.test(href)) return { href, external: true };
  // Pure fragment or already site-absolute: leave untouched.
  if (href.startsWith('#') || href.startsWith('/')) {
    return { href, external: false };
  }

  const hashIndex = href.indexOf('#');
  const rawPath = hashIndex === -1 ? href : href.slice(0, hashIndex);
  const hash = hashIndex === -1 ? '' : href.slice(hashIndex + 1);

  const lastSlash = contentPath.lastIndexOf('/');
  const baseDir = lastSlash === -1 ? '' : contentPath.slice(0, lastSlash);

  const segments: string[] = [];
  for (const part of [...baseDir.split('/'), ...rawPath.split('/')]) {
    if (part === '' || part === '.') continue;
    if (part === '..') {
      segments.pop();
      continue;
    }
    segments.push(part);
  }

  if (segments.length > 0) {
    segments[segments.length - 1] = segments[segments.length - 1].replace(
      /\.md$/i,
      '',
    );
    if (segments[segments.length - 1] === 'index') segments.pop();
  }

  const base = `/${locale}`;
  const resolved = segments.length > 0 ? `${base}/${segments.join('/')}` : base;
  return { href: hash ? `${resolved}#${hash}` : resolved, external: false };
}
