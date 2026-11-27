import assert from 'node:assert/strict';
import test from 'node:test';
import rehypeStringify from 'rehype-stringify';
import remarkGfm from 'remark-gfm';
import remarkParse from 'remark-parse';
import remarkRehype from 'remark-rehype';
import { unified } from 'unified';
import { remarkGithubAlerts } from './github-alerts.ts';

function html(markdown: string): string {
  return String(
    unified()
      .use(remarkParse)
      .use(remarkGfm)
      .use(remarkGithubAlerts)
      .use(remarkRehype)
      .use(rehypeStringify)
      .processSync(markdown),
  );
}

test('transforms a [!NOTE] blockquote into a callout div', () => {
  const out = html('> [!NOTE]\n> Useful information.');
  assert.match(out, /<div class="callout callout-note" data-callout="note">/);
  assert.match(out, /<p class="callout-title"><strong>Note<\/strong><\/p>/);
  assert.match(out, /<p>Useful information\.<\/p>/);
  assert.doesNotMatch(out, /\[!NOTE\]/);
  assert.doesNotMatch(out, /<blockquote>/);
});

test('supports all five GitHub alert kinds with labels', () => {
  const kinds = [
    ['NOTE', 'Note'],
    ['TIP', 'Tip'],
    ['IMPORTANT', 'Important'],
    ['WARNING', 'Warning'],
    ['CAUTION', 'Caution'],
  ] as const;
  for (const [kind, label] of kinds) {
    const out = html(`> [!${kind}]\n> Body text.`);
    assert.match(out, new RegExp(`callout-${kind.toLowerCase()}`));
    assert.match(out, new RegExp(`<strong>${label}</strong>`));
    assert.match(out, /Body text\./);
  }
});

test('keeps multi-paragraph and formatted alert content', () => {
  const out = html('> [!TIP]\n> First **bold** line.\n>\n> Second paragraph.');
  assert.match(out, /<strong>bold<\/strong>/);
  assert.match(out, /<p>Second paragraph\.<\/p>/);
});

test('leaves ordinary blockquotes untouched', () => {
  const out = html('> Just a quote.');
  assert.match(out, /<blockquote>/);
  assert.doesNotMatch(out, /callout/);
});

test('ignores lowercase or unknown markers', () => {
  assert.match(html('> [!note]\n> text'), /<blockquote>/);
  assert.match(html('> [!HINT]\n> text'), /<blockquote>/);
});

test('handles an alert with no body', () => {
  const out = html('> [!WARNING]');
  assert.match(out, /callout-warning/);
  assert.match(out, /<strong>Warning<\/strong>/);
});
