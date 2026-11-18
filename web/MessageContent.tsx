import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Source } from "../shared/types.ts";

function webUrl(value: string) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url : undefined;
  } catch {
    return undefined;
  }
}

// Relative app routes are useful citations, but must never navigate Relay itself.
export function citedSource(href: string, sources: Source[]) {
  const absolute = webUrl(href);
  if (absolute)
    return sources.find(
      (source) => webUrl(source.sourceUrl)?.href === absolute.href,
    );
  if (!href.startsWith("#/") && !href.startsWith("/") && !href.startsWith("./"))
    return undefined;
  if (href.startsWith("//")) return undefined;
  const exact = sources.find((source) => source.sourceUrl === href);
  if (exact) return exact;
  const matches = sources.filter((source) => {
    const url = webUrl(source.sourceUrl);
    if (!url) return false;
    if (href.startsWith("#/")) return url.hash === href;
    return (
      `${url.pathname}${url.search}${url.hash}` === href.replace(/^\.\//, "/")
    );
  });
  return matches.length === 1 ? matches[0] : undefined;
}

export default function MessageContent({
  text,
  sources,
  onOpenSource,
}: {
  text: string;
  sources: Source[];
  onOpenSource: (source: Source) => void;
}) {
  return (
    <Markdown
      remarkPlugins={[remarkGfm]}
      skipHtml
      components={{
        a({ children, href }) {
          const source = href && citedSource(href, sources);
          if (source)
            return (
              <button
                className="inline-source"
                onClick={() => onOpenSource(source)}
                title="Open cited snapshot"
              >
                {children}
              </button>
            );
          if (href && (webUrl(href) || href.startsWith("mailto:")))
            return (
              <a href={href} target="_blank" rel="noopener noreferrer">
                {children}
              </a>
            );
          if (href?.startsWith("#user-content-"))
            return <a href={href}>{children}</a>;
          return <>{children}</>;
        },
        code({ children, className }) {
          const value = typeof children === "string" ? children : "";
          const source = !value.includes("\n") && citedSource(value, sources);
          const code = <code className={className}>{children}</code>;
          return source ? (
            <button
              className="inline-source"
              onClick={() => onOpenSource(source)}
              title="Open cited snapshot"
            >
              {code}
            </button>
          ) : (
            code
          );
        },
        table({ children, ...props }) {
          const { node: _node, ...tableProps } = props;
          return (
            <div
              className="markdown-table"
              role="region"
              aria-label="Response table"
              tabIndex={0}
            >
              <table {...tableProps}>{children}</table>
            </div>
          );
        },
        img({ alt }) {
          return <span>{alt}</span>;
        },
      }}
    >
      {text}
    </Markdown>
  );
}
