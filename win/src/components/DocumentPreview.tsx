import type { ReactNode } from "react";
import type { OCRPage } from "../models/ocr";
import { pageDisplayText } from "../models/ocr";

interface Props {
  filename: string;
  page: OCRPage | undefined;
}

interface HeadingAnchor {
  id: string;
  level: number;
  text: string;
}

export default function DocumentPreview({ filename, page }: Props) {
  const text = page ? pageDisplayText(page) : "";
  const headings = extractHeadingAnchors(text);

  return (
    <div className="doc-pane">
      <div className="doc-preview-shell">
        <div className="doc-preview-header">
          <span>Converted document</span>
          <strong>{filename}</strong>
        </div>
        {text.trim() ? (
          <div className={`doc-preview-body ${headings.length ? "with-outline" : ""}`}>
            {headings.length > 0 && (
              <nav className="doc-outline" aria-label="Document outline">
                {headings.map((heading) => (
                  <a
                    key={heading.id}
                    href={`#${heading.id}`}
                    className={`level-${heading.level}`}
                  >
                    {heading.text}
                  </a>
                ))}
              </nav>
            )}
            <div className="markdown-preview">{renderMarkdown(text, headings)}</div>
          </div>
        ) : (
          <div className="placeholder">
            <p>No converted text available.</p>
          </div>
        )}
      </div>
    </div>
  );
}

function renderMarkdown(text: string, headings: HeadingAnchor[]): ReactNode[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const nodes: ReactNode[] = [];
  let i = 0;
  let headingIndex = 0;

  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i += 1;
      continue;
    }

    if (line.trim().startsWith("```")) {
      const code: string[] = [];
      i += 1;
      while (i < lines.length && !lines[i].trim().startsWith("```")) {
        code.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) i += 1;
      nodes.push(<pre key={nodes.length}>{code.join("\n")}</pre>);
      continue;
    }

    const heading = /^(#{1,4})\s+(.+)$/.exec(line);
    if (heading) {
      const level = heading[1].length;
      const content = renderInline(heading[2]);
      const id = headings[headingIndex]?.id ?? slugify(heading[2], headingIndex);
      headingIndex += 1;
      if (level === 1) nodes.push(<h1 id={id} key={nodes.length}>{content}</h1>);
      else if (level === 2) nodes.push(<h2 id={id} key={nodes.length}>{content}</h2>);
      else if (level === 3) nodes.push(<h3 id={id} key={nodes.length}>{content}</h3>);
      else nodes.push(<h4 id={id} key={nodes.length}>{content}</h4>);
      i += 1;
      continue;
    }

    if (isTableStart(lines, i)) {
      const header = splitTableRow(lines[i]);
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && isTableRow(lines[i])) {
        rows.push(splitTableRow(lines[i]));
        i += 1;
      }
      nodes.push(
        <table key={nodes.length}>
          <thead>
            <tr>{header.map((cell, c) => <th key={c}>{renderInline(cell)}</th>)}</tr>
          </thead>
          <tbody>
            {rows.map((row, r) => (
              <tr key={r}>{row.map((cell, c) => <td key={c}>{renderInline(cell)}</td>)}</tr>
            ))}
          </tbody>
        </table>
      );
      continue;
    }

    if (/^\s*>\s+/.test(line)) {
      const quote: string[] = [];
      while (i < lines.length && /^\s*>\s+/.test(lines[i])) {
        quote.push(lines[i].replace(/^\s*>\s+/, ""));
        i += 1;
      }
      nodes.push(
        <blockquote key={nodes.length}>
          {quote.map((value, n) => <p key={n}>{renderInline(value)}</p>)}
        </blockquote>
      );
      continue;
    }

    if (/^\s*([-*+])\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*([-*+])\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*([-*+])\s+/, ""));
        i += 1;
      }
      nodes.push(
        <ul key={nodes.length}>
          {items.map((item, n) => <li key={n}>{renderInline(item)}</li>)}
        </ul>
      );
      continue;
    }

    if (/^\s*\d+[.)]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*\d+[.)]\s+/, ""));
        i += 1;
      }
      nodes.push(
        <ol key={nodes.length}>
          {items.map((item, n) => <li key={n}>{renderInline(item)}</li>)}
        </ol>
      );
      continue;
    }

    const paragraph: string[] = [line.trim()];
    i += 1;
    while (i < lines.length && lines[i].trim() && !startsBlock(lines, i)) {
      paragraph.push(lines[i].trim());
      i += 1;
    }
    nodes.push(<p key={nodes.length}>{renderInline(paragraph.join(" "))}</p>);
  }

  return nodes;
}

function extractHeadingAnchors(text: string): HeadingAnchor[] {
  const anchors: HeadingAnchor[] = [];
  for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
    const match = /^(#{1,4})\s+(.+)$/.exec(line);
    if (!match) continue;
    anchors.push({
      id: slugify(match[2], anchors.length),
      level: match[1].length,
      text: match[2].trim(),
    });
  }
  return anchors;
}

function slugify(text: string, index: number): string {
  const slug = text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 48);
  return `section-${slug || "heading"}-${index}`;
}

function renderInline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const pattern = /(`[^`]+`|\*\*[^*]+\*\*)/g;
  let cursor = 0;
  for (const match of text.matchAll(pattern)) {
    const index = match.index ?? cursor;
    if (index > cursor) nodes.push(text.slice(cursor, index));
    const token = match[0];
    if (token.startsWith("`")) {
      nodes.push(<code key={nodes.length}>{token.slice(1, -1)}</code>);
    } else {
      nodes.push(<strong key={nodes.length}>{token.slice(2, -2)}</strong>);
    }
    cursor = index + token.length;
  }
  if (cursor < text.length) nodes.push(text.slice(cursor));
  return nodes;
}

function startsBlock(lines: string[], index: number): boolean {
  const line = lines[index];
  return (
    /^(#{1,4})\s+/.test(line) ||
    line.trim().startsWith("```") ||
    /^\s*>\s+/.test(line) ||
    /^\s*([-*+])\s+/.test(line) ||
    /^\s*\d+[.)]\s+/.test(line) ||
    isTableStart(lines, index)
  );
}

function isTableStart(lines: string[], index: number): boolean {
  return isTableRow(lines[index]) && index + 1 < lines.length && isTableSeparator(lines[index + 1]);
}

function isTableRow(line: string): boolean {
  return line.includes("|") && splitTableRow(line).length >= 2;
}

function isTableSeparator(line: string): boolean {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function splitTableRow(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}
