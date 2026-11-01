// Swift highlighting with Shiki, using the JavaScript regex engine so it needs no WebAssembly
// and fits in the single-file build. Tokens carry both theme colors; CSS picks one.

import { createHighlighterCore, type HighlighterCore, type ThemedToken } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import swift from "shiki/langs/swift.mjs";
import githubLight from "shiki/themes/github-light.mjs";
import githubDark from "shiki/themes/github-dark.mjs";

export interface Tok {
  text: string;
  light?: string;
  dark?: string;
}

let highlighter: Promise<HighlighterCore> | null = null;
const getHighlighter = () =>
  (highlighter ??= createHighlighterCore({
    themes: [githubLight, githubDark],
    langs: [swift],
    engine: createJavaScriptRegexEngine(),
  }));

const MAX_CHARS = 400_000;
const cache = new Map<string, Promise<Tok[][]>>();

const plain = (text: string): Tok[][] => text.split("\n").map((l) => [{ text: l }]);

/** Lines of tokens for a whole file. Highlighting needs the whole file, because state carries across lines. */
export function highlightFile(key: string, file: string, text: string): Promise<Tok[][]> {
  let p = cache.get(key);
  if (!p) {
    p = !file.endsWith(".swift") || text.length > MAX_CHARS ? Promise.resolve(plain(text)) : tokenize(text).catch(() => plain(text));
    cache.set(key, p);
  }
  return p;
}

async function tokenize(text: string): Promise<Tok[][]> {
  const h = await getHighlighter();
  const { tokens } = h.codeToTokens(text, {
    lang: "swift",
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
