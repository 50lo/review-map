import swift from "./icons/swift.svg";
import typescript from "./icons/typescript.svg";
import type { Language } from "./languages";

const ICONS = {
  swift: { name: "Swift", src: swift },
  typescript: { name: "TypeScript", src: typescript },
};

export function LanguageBadges({ languages, external = false }: { languages: Language[]; external?: boolean }) {
  if (!languages.length) return null;
  return (
    <span className="language-badges">
      {languages.map((language) => {
        const { name, src } = ICONS[language];
        const label = external ? `${name} ecosystem dependency` : name;
        return <img key={language} className={`language-icon lang-${language}`} src={src} alt={label} title={label} draggable={false} />;
      })}
    </span>
  );
}
