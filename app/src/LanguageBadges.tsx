import { languageDefinition, type Language } from "./languages";

export function LanguageBadges({ languages, external = false }: { languages: Language[]; external?: boolean }) {
  if (!languages.length) return null;
  return (
    <span className="language-badges">
      {languages.map((language) => {
        const { name, icon } = languageDefinition(language);
        const label = external ? `${name} ecosystem dependency` : name;
        return <img key={language} className={`language-icon lang-${language}`} src={icon} alt={label} title={label} draggable={false} />;
      })}
    </span>
  );
}
