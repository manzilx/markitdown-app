interface Props {
  visible: boolean;
  findText: string;
  replaceText: string;
  matchCount: number;
  matchIndex: number;
  onFindChange: (v: string) => void;
  onReplaceChange: (v: string) => void;
  onNext: () => void;
  onPrev: () => void;
  onReplace: () => void;
  onReplaceAll: () => void;
  onClose: () => void;
}

export default function FindReplaceBar({
  visible,
  findText,
  replaceText,
  matchCount,
  matchIndex,
  onFindChange,
  onReplaceChange,
  onNext,
  onPrev,
  onReplace,
  onReplaceAll,
  onClose,
}: Props) {
  if (!visible) return null;
  return (
    <div className="find-bar">
      <input
        value={findText}
        onChange={(e) => onFindChange(e.target.value)}
        placeholder="Find"
        autoFocus
      />
      <input
        value={replaceText}
        onChange={(e) => onReplaceChange(e.target.value)}
        placeholder="Replace"
      />
      <span className="find-count">
        {matchCount === 0 ? "No matches" : `${matchIndex + 1} / ${matchCount}`}
      </span>
      <button type="button" onClick={onPrev}>
        ↑
      </button>
      <button type="button" onClick={onNext}>
        ↓
      </button>
      <button type="button" onClick={onReplace}>
        Replace
      </button>
      <button type="button" onClick={onReplaceAll}>
        Replace All
      </button>
      <button type="button" className="ghost" onClick={onClose}>
        ✕
      </button>
    </div>
  );
}
