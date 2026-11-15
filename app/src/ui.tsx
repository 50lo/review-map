import { useState } from "react";
import { flagLabel } from "./graph";
import { signatureSegments } from "./diff";
import { setReviewed, useReview } from "./review";
import type { ReviewItem } from "./types";

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
export function Signature({ e }: { e: ReviewItem }) {
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

/** The reviewed checkbox of a review item. */
export function ReviewedBox({ id, compact }: { id: string; compact?: boolean }) {
  const review = useReview();
  const on = !!review.reviewed[id];
  return (
    <label className={`reviewed ${compact ? "compact" : ""} ${on ? "on" : ""}`} title={on ? "Reviewed" : "Mark as reviewed"} onClick={(ev) => ev.stopPropagation()}>
      <input type="checkbox" checked={on} onChange={(ev) => setReviewed(id, ev.target.checked)} />
      {!compact && <span>Reviewed</span>}
    </label>
  );
}

/** The LLM's one-line behavior summary of a review item or component. */
export const LLMSummary = ({ text }: { text: string }) => (
  <div className="llm-text llm-summary" title="Summary written by the LLM">
    {text}
  </div>
);

/** Switches ranking, and every other LLM annotation, between the analyzer's scores and the LLM's. */
export function RankingToggle({ on, setOn }: { on: boolean; setOn: (on: boolean) => void }) {
  return (
    <div className="ranking-toggle" role="group" aria-label="Ranking">
      <span className="muted small">Ranking</span>
      <button className={`seg ${on ? "" : "on"}`} aria-pressed={!on} onClick={() => setOn(false)}>
        Deterministic
      </button>
      <button className={`seg ${on ? "on" : ""}`} aria-pressed={on} onClick={() => setOn(true)}>
        LLM
      </button>
    </div>
  );
}
