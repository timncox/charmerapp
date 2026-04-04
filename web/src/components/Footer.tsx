import type { MediaItem } from "@/lib/media";

interface FooterProps {
  items: MediaItem[];
}

export function Footer({ items }: FooterProps) {
  const photoCount = items.filter((i) => i.type === "photo").length;
  const videoCount = items.filter((i) => i.type === "video").length;

  const latestDate = items.length > 0
    ? new Date(
        Math.max(...items.map((i) => new Date(i.timestamp).getTime()))
      ).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })
    : null;

  const parts: string[] = [];
  if (photoCount > 0) parts.push(`${photoCount} photo${photoCount !== 1 ? "s" : ""}`);
  if (videoCount > 0) parts.push(`${videoCount} video${videoCount !== 1 ? "s" : ""}`);

  return (
    <footer>
      {/* Thin top accent — matching the header rainbow */}
      <div className="flex h-[2px]">
        <div className="flex-1" style={{ background: "var(--kodak-red)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-orange)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-amber)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-gold)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-green)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-blue)" }} />
      </div>
      <div
        className="flex items-center justify-between px-5 py-2.5"
        style={{
          background: "linear-gradient(180deg, var(--kodak-gold) 0%, #f0a800 100%)",
        }}
      >
        <span className="text-[11px] font-bold tracking-wide text-neutral-900 uppercase">
          {parts.join(" \u00B7 ") || "No media"}
        </span>
        <div className="flex items-center gap-3">
          {latestDate && (
            <span className="text-[10px] font-medium tracking-wide text-black/40 uppercase">
              {latestDate}
            </span>
          )}
          <span
            className="text-[9px] font-bold tracking-[0.2em] text-black/25"
            style={{ fontStyle: "italic" }}
          >
            Shot on Charmera
          </span>
        </div>
      </div>
    </footer>
  );
}
