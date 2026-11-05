import type { ChangeModel } from "./types";

export type Language = "swift" | "typescript";
const ORDER: Language[] = ["swift", "typescript"];

/** The ecosystem indicated by a source file or manifest, not a package-name guess. */
function languageOfPath(path: string): Language | undefined {
  if (/\.swift$|\.xcodeproj(?:\/project\.pbxproj)?$|(?:^|\/)Package\.resolved$/.test(path)) return "swift";
  if (/\.(?:ts|tsx|mts|cts)$|(?:^|\/)(?:package(?:-lock)?\.json|tsconfig(?:\.[^/]+)?\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?)$/.test(path)) return "typescript";
  return undefined;
}

/** Works with existing models, including unchanged nodes with no changed entities. */
export function componentLanguages(model: ChangeModel): Map<string, Language[]> {
  const components = new Map(model.components.map((c) => [c.id, c]));
  const known = new Map(model.components.map((c) => [c.id, new Set<Language>()]));
  const addPath = (id: string, path: string) => {
    const lang = languageOfPath(path);
    if (lang) known.get(id)?.add(lang);
  };
  for (const c of model.components) {
    if (c.kind === "spmTarget" || c.kind === "xcodeTarget") known.get(c.id)!.add("swift");
    if (c.kind === "npmPackage" || c.kind === "tsconfig") known.get(c.id)!.add("typescript");
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
