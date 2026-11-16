// Swift and TypeScript highlighting with Shiki, using the JavaScript regex engine so it needs no WebAssembly
// and fits in the single-file build. Tokens carry both theme colors; CSS picks one.

import { createHighlighterCore, type HighlighterCore, type ThemedToken } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import githubLight from "shiki/themes/github-light.mjs";
import githubDark from "shiki/themes/github-dark.mjs";
import { highlightGrammars, highlightLanguageOf } from "./languages";

export interface Tok {
  text: string;
  light?: string;
  dark?: string;
}

let highlighter: Promise<HighlighterCore> | null = null;
const getHighlighter = () =>
  (highlighter ??= createHighlighterCore({
    themes: [githubLight, githubDark],
    langs: highlightGrammars(),
    engine: createJavaScriptRegexEngine(),
  }));

const MAX_CHARS = 400_000;
/** Tokens by key, with the text they were made from: the same key can name other text in another review. */
const cache = new Map<string, { text: string; tokens: Promise<Tok[][]> }>();

const plain = (text: string): Tok[][] => text.split("\n").map((l) => [{ text: l }]);

/** The Shiki language for a file, by extension. */
export const languageOf = highlightLanguageOf;

/**
 * Lines of tokens for a whole file. Highlighting needs the whole file, because state carries across lines.
 * Cached tokens are reused only for the same text, so a key reused by another review is highlighted again.
 */
export function highlightFile(key: string, file: string, text: string): Promise<Tok[][]> {
  const hit = cache.get(key);
  if (hit && hit.text === text) return hit.tokens;
  const lang = languageOf(file);
  const tokens = !lang || text.length > MAX_CHARS ? Promise.resolve(plain(text)) : tokenize(text, lang).catch(() => plain(text));
  cache.set(key, { text, tokens });
  return tokens;
}

async function tokenize(text: string, lang: string): Promise<Tok[][]> {
  const h = await getHighlighter();
  const { tokens } = h.codeToTokens(text, {
    lang,
    themes: { light: "github-light", dark: "github-dark" },
    defaultColor: false,
  });
  return tokens.map((line: ThemedToken[]) =>
    line.map((t) => {
      const style = (t.htmlStyle ?? {}) as Record<string, string>;
      return { text: t.content, light: style["--shiki-light"], dark: style["--shiki-dark"] };
    }),
  );
}
