import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveHref } from './links.ts';

test('resolves sibling links against the current doc directory', () => {
  assert.deepEqual(resolveHref('./configuration', 'zephyrus/index.md', 'en'), {
    href: '/en/zephyrus/configuration',
    external: false,
  });
  assert.deepEqual(
    resolveHref('./advanced#tuning', 'zephyrus/configuration.md', 'en'),
    { href: '/en/zephyrus/advanced#tuning', external: false },
  );
});

test('resolves parent-relative links to other apps (trailing slash → index)', () => {
  assert.deepEqual(resolveHref('../eros/', 'zephyrus/configuration.md', 'en'), {
    href: '/en/eros',
    external: false,
  });
  assert.deepEqual(resolveHref('../', 'zephyrus/configuration.md', 'en'), {
    href: '/en',
    external: false,
  });
});

test('resolves links from the suite home', () => {
  assert.deepEqual(resolveHref('./zephyrus/', 'index.md', 'en'), {
    href: '/en/zephyrus',
    external: false,
  });
});

test('strips .md extensions and index.md targets', () => {
  assert.deepEqual(
    resolveHref('./configuration.md', 'zephyrus/index.md', 'en'),
    { href: '/en/zephyrus/configuration', external: false },
  );
  assert.deepEqual(resolveHref('../eros/index.md', 'zephyrus/x.md', 'en'), {
    href: '/en/eros',
    external: false,
  });
});

test('preserves the locale segment', () => {
  assert.deepEqual(resolveHref('./setup', 'eros/index.md', 'tr'), {
    href: '/tr/eros/setup',
    external: false,
  });
});

test('marks external links and leaves them untouched', () => {
  for (const href of [
    'https://example.com/page',
    'http://example.com',
    'mailto:hi@example.com',
    '//cdn.example.com/x',
  ]) {
    assert.deepEqual(resolveHref(href, 'index.md', 'en'), {
      href,
      external: true,
    });
  }
});

test('passes fragments and site-absolute paths through', () => {
  assert.deepEqual(resolveHref('#section', 'zephyrus/x.md', 'en'), {
    href: '#section',
    external: false,
  });
  assert.deepEqual(resolveHref('/en/eros', 'zephyrus/x.md', 'en'), {
    href: '/en/eros',
    external: false,
  });
});
