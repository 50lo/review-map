import type { CSSProperties } from "react";
import { languageDefinition, type Language } from "./languages";

export function LanguageBadges({ languages, external = false }: { languages: Language[]; external?: boolean }) {
  if (!languages.length) return null;
  return (
    <span className="language-badges">
      {languages.map((language) => {
        const { name, icon } = languageDefinition(language);
        const label = external ? `${name} ecosystem dependency` : name;
        // --icon lets CSS draw the icon as a mask, in the muted color of a dimmed node.
        const style = { "--icon": `url("${icon}")` } as CSSProperties;
        return <img key={language} className={`language-icon lang-${language}`} src={icon} alt={label} title={label} style={style} draggable={false} />;
      })}
    </span>
  );
}
