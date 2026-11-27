import { readFileSync } from 'node:fs';
import path from 'node:path';
import { cache } from 'react';
import type { Locale } from './i18n';
import type en from '../locales/en.json';

/** Shape of every locale dictionary, inferred from the English source. */
export type Dictionary = typeof en;

/**
 * Server-readable UI strings. Loaded from `locales/<locale>.json` at build
 * time (the site is a static export, so this never runs in a browser).
 * Adding a language only requires dropping a new JSON file next to en.json.
 */
export const getDictionary = cache((locale: Locale): Dictionary => {
  const file = path.join(process.cwd(), 'locales', `${locale}.json`);
  return JSON.parse(readFileSync(file, 'utf8')) as Dictionary;
});
