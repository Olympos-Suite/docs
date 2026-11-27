import type { Blockquote, Paragraph, Root, Strong } from 'mdast';
import type { Plugin } from 'unified';
import { visit } from 'unist-util-visit';

/**
 * GitHub-style alerts:
 *
 *   > [!NOTE]
 *   > Useful information.
 *
 * Supported kinds: NOTE, TIP, IMPORTANT, WARNING, CAUTION (uppercase, as on
 * GitHub). The blockquote is rewritten to render as
 * `<div class="callout callout-<kind>">` with a leading
 * `<p class="callout-title"><strong>Note</strong></p>` label. The rewrite uses
 * mdast `data.hName` / `data.hProperties`, which mdast-util-to-hast applies
 * when react-markdown converts the tree to HTML.
 */
const ALERT_RE = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:\r?\n|$)/;

const LABELS: Record<string, string> = {
  NOTE: 'Note',
  TIP: 'Tip',
  IMPORTANT: 'Important',
  WARNING: 'Warning',
  CAUTION: 'Caution',
};

export const remarkGithubAlerts: Plugin<[], Root> = () => (tree) => {
  visit(tree, 'blockquote', (node: Blockquote) => {
    const first = node.children[0];
    if (!first || first.type !== 'paragraph') return;
    const head = first.children[0];
    if (!head || head.type !== 'text') return;

    const match = ALERT_RE.exec(head.value);
    if (!match) return;
    const kind = match[1].toLowerCase();

    // Strip the `[!KIND]` marker (and its trailing newline) from the text.
    head.value = head.value.slice(match[0].length);
    if (head.value === '') first.children.shift();
    if (first.children.length === 0) node.children.shift();

    node.data = {
      ...node.data,
      hName: 'div',
      hProperties: {
        className: ['callout', `callout-${kind}`],
        'data-callout': kind,
      },
    };

    const title: Paragraph = {
      type: 'paragraph',
      data: { hProperties: { className: ['callout-title'] } },
      children: [
        {
          type: 'strong',
          children: [{ type: 'text', value: LABELS[match[1]] }],
        } as Strong,
      ],
    };
    node.children.unshift(title);
  });
};
