import { useState } from "react";
import { flagLabel } from "./graph";
import { signatureSegments } from "./diff";
import type { Entity } from "./types";

export const Chips = ({ flags }: { flags: string[] }) =>
  flags.length ? (
    <span className="chips">
      {flags.map((f) => (
        <span key={f} className="chip" title={f}>
          {flagLabel(f)}
        </span>
      ))}
    </span>
  ) : null;

export const StatusDot = ({ status }: { status: string }) => <span className={`dot dot-${status}`} />;

export const ChangeTag = ({ change }: { change: string }) => <span className={`change ch-${change}`}>{change}</span>;

/**
 * The head signature with changed tokens highlighted. The base signature is shown on hover, or
 * on tap where there is no hover, never side by side.
 */
export function Signature({ e }: { e: Entity }) {
  const [showBase, setShowBase] = useState(false);
  const { base, head } = e.signature;
  if (!head) return base ? <div className="sig mono removed-sig">{base}</div> : null;
  const differs = base !== undefined && base !== head;
  return (
    <div className="sig-wrap">
      <div className="sig mono" title={differs ? `base: ${base}` : undefined}>
        {signatureSegments(base, head).map((s, i) =>
          s.changed ? (
            <mark key={i} className="tok-changed">
              {s.text}
            </mark>
          ) : (
            <span key={i}>{s.text}</span>
          ),
        )}
        {differs && (
          <button
            className="base-toggle"
            title="Show the base signature"
            onClick={(ev) => {
              ev.stopPropagation();
              setShowBase(!showBase);
            }}
          >
            {showBase ? "hide base" : "base"}
          </button>
        )}
      </div>
      {showBase && <div className="sig mono base-sig">{base}</div>}
    </div>
  );
}
