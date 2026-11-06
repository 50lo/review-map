import type { LanguageInput } from "shiki/core";
import swiftGrammar from "shiki/langs/swift.mjs";
import typescriptGrammar from "shiki/langs/typescript.mjs";
import tsxGrammar from "shiki/langs/tsx.mjs";
import goGrammar from "shiki/langs/go.mjs";
import swiftIcon from "./icons/swift.svg";
import typescriptIcon from "./icons/typescript.svg";
import goIcon from "./icons/go.svg";
import type { ChangeReport, ReviewItem } from "./types";

interface LanguageDefinition {
  id: string;
  name: string;
  extensions: Record<string, { language: string; grammar: LanguageInput }>;
  manifests: readonly RegExp[];
  componentKinds: readonly string[];
  icon: string;
  kinds: Record<string, string | ((entity: ReviewItem) => string)>;
}

/** Viewer language facts, in badge order. Adding a language adds one entry here. */
export const LANGUAGES = [
  {
    id: "swift",
    name: "Swift",
    extensions: { swift: { language: "swift", grammar: swiftGrammar } },
    manifests: [/\.xcodeproj(?:\/project\.pbxproj)?$/, /(?:^|\/)Package\.resolved$/],
    componentKinds: ["spmTarget", "xcodeTarget"],
    icon: swiftIcon,
    kinds: {},
  },
  {
    id: "typescript",
    name: "TypeScript",
    extensions: {
      ts: { language: "typescript", grammar: typescriptGrammar },
      tsx: { language: "tsx", grammar: tsxGrammar },
      mts: { language: "typescript", grammar: typescriptGrammar },
      cts: { language: "typescript", grammar: typescriptGrammar },
    },
    manifests: [/(?:^|\/)(?:package(?:-lock)?\.json|tsconfig(?:\.[^/]+)?\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?)$/],
    componentKinds: ["npmPackage", "tsconfig"],
    icon: typescriptIcon,
    kinds: {
      protocol: "interface", case: "member", init: "constructor", typealias: "type", func: "function",
      var: (entity: ReviewItem) => entity.qualifiedName.includes(".") ? "property" : "variable",
    },
  },
  {
    id: "go",
    name: "Go",
    extensions: { go: { language: "go", grammar: goGrammar } },
    manifests: [/(?:^|\/)go\.(?:mod|sum|work)$/],
    componentKinds: ["goPackage"],
    icon: goIcon,
    kinds: {
      protocol: "interface", typealias: "type",
      func: (entity: ReviewItem) => entity.qualifiedName.slice(0, -2).includes(".") ? "method" : "function",
      var: (entity: ReviewItem) => entity.qualifiedName.includes(".") ? "field" : "variable",
    },
  },
] as const satisfies readonly LanguageDefinition[];

export type Language = (typeof LANGUAGES)[number]["id"];
const ORDER = LANGUAGES.map((language) => language.id);
const definitions: readonly LanguageDefinition[] = LANGUAGES;

export const languageDefinition = (id: Language) => LANGUAGES.find((language) => language.id === id)!;

function sourceLanguage(path: string): LanguageDefinition | undefined {
  return definitions.find((language) => Object.keys(language.extensions).some((ext) => path.endsWith(`.${ext}`)));
}

/** The ecosystem indicated by a source file or manifest, not a package-name guess. */
export function languageOfPath(path: string): Language | undefined {
  return LANGUAGES.find((language) =>
    Object.keys(language.extensions).some((ext) => path.endsWith(`.${ext}`)) || language.manifests.some((pattern) => pattern.test(path)),
  )?.id;
}

/** The Shiki language for a file, by extension. */
export function highlightLanguageOf(file: string): string | undefined {
  const ext = file.slice(file.lastIndexOf(".") + 1);
  return definitions.find((language) => Object.hasOwn(language.extensions, ext))?.extensions[ext].language;
}

/** Only load grammars the table's extensions use, once per grammar. */
export const highlightGrammars = () => [...new Set(definitions.flatMap((language) => Object.values(language.extensions).map(({ grammar }) => grammar)))];

/** Review item kinds as the entity's language names them. Unknown paths keep the model's kind. */
export function entityKindLabel(entity: ReviewItem): string {
  const kinds = sourceLanguage(entity.location.file)?.kinds;
  const kind = kinds && Object.hasOwn(kinds, entity.kind) ? kinds[entity.kind] : undefined;
  return typeof kind === "function" ? kind(entity) : kind ?? entity.kind;
}

/** Works with existing models, including unchanged nodes with no changed entities. */
export function componentLanguages(model: ChangeReport): Map<string, Language[]> {
  const components = new Map(model.components.map((c) => [c.id, c]));
  const known = new Map(model.components.map((c) => [c.id, new Set<Language>()]));
  const addPath = (id: string, path: string) => {
    const lang = languageOfPath(path);
    if (lang) known.get(id)?.add(lang);
  };
  for (const c of model.components) {
    for (const language of LANGUAGES) {
      if ((language.componentKinds as readonly string[]).includes(c.kind)) known.get(c.id)!.add(language.id);
    }
    for (const path of c.paths) addPath(c.id, path);
  }
  for (const e of model.entities) {
    addPath(e.component, e.location.file);
    if (e.baseLocation) addPath(e.component, e.baseLocation.file);
    for (const u of [...(e.usedBy ?? []), ...(e.dependsOn ?? [])]) addPath(u.component, u.file);
  }
  for (const edge of model.edges) {
    for (const ref of edge.refs) {
      // A reference's file belongs to the caller. Only external nodes take the
      // caller's ecosystem: it doesn't tell us the callee's implementation language.
      addPath(edge.from, ref.file);
      if (components.get(edge.to)?.kind === "external") addPath(edge.to, ref.file);
    }
  }

  // Split folders inherit their target's ecosystem. Groups also show the languages
  // of their contents when expanded or collapsed. Guard malformed parent cycles.
  for (const c of model.components) {
    const langs = known.get(c.id)!;
    if (langs.size) continue;
    const seen = new Set([c.id]);
    let parent = c.parent;
    while (parent && !seen.has(parent)) {
      seen.add(parent);
      for (const lang of known.get(parent) ?? []) langs.add(lang);
      if (langs.size) break;
      parent = components.get(parent)?.parent;
    }
  }
  for (const c of model.components) {
    const seen = new Set([c.id]);
    let parent = c.parent;
    while (parent && !seen.has(parent)) {
      seen.add(parent);
      for (const lang of known.get(c.id)!) known.get(parent)?.add(lang);
      parent = components.get(parent)?.parent;
    }
  }
  return new Map([...known].map(([id, langs]) => [id, ORDER.filter((lang) => langs.has(lang))]));
}
