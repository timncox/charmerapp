import type { MediaItem } from "@/lib/media";

interface MediaTileProps {
  item: MediaItem;
  index: number;
  onClick: () => void;
}

export function MediaTile({ item, index, onClick }: MediaTileProps) {
  const frameNumber = item.filename.replace(/^(PICT|MOVI)/, "").replace(/\.\w+$/, "");

  if (item.type === "video") {
    return (
      <button
        onClick={onClick}
        className="group relative aspect-[4/3] w-full overflow-hidden bg-neutral-900 cursor-pointer"
        style={{
          border: "1.5px solid var(--contact-border)",
          transition: "box-shadow 0.15s ease, border-color 0.15s ease",
        }}
        onMouseEnter={(e) => {
          e.currentTarget.style.boxShadow = "0 0 0 2px var(--kodak-gold)";
          e.currentTarget.style.borderColor = "var(--kodak-gold)";
        }}
        onMouseLeave={(e) => {
          e.currentTarget.style.boxShadow = "none";
          e.currentTarget.style.borderColor = "var(--contact-border)";
        }}
      >
        <video
          src={item.url}
          muted
          playsInline
          preload="metadata"
          className="h-full w-full object-cover pointer-events-none"
        />
        {/* Play icon overlay */}
        <div className="absolute inset-0 flex items-center justify-center">
          <div
            className="flex h-9 w-9 items-center justify-center rounded-full"
            style={{ background: "rgba(0,0,0,0.5)", backdropFilter: "blur(4px)" }}
          >
            <div className="ml-0.5 h-0 w-0 border-y-[6px] border-l-[10px] border-y-transparent border-l-white/90" />
          </div>
        </div>
        {/* Frame number — contact sheet style */}
        <span
          className="absolute bottom-0 left-0 right-0 px-1.5 py-[2px] font-mono text-[9px] leading-tight"
          style={{
            color: "var(--frame-text)",
            background: "linear-gradient(transparent, rgba(234,230,223,0.92))",
          }}
        >
          {frameNumber}
        </span>
      </button>
    );
  }

  return (
    <button
      onClick={onClick}
      className="group relative aspect-[4/3] w-full overflow-hidden cursor-pointer"
      style={{
        border: "1.5px solid var(--contact-border)",
        transition: "box-shadow 0.15s ease, border-color 0.15s ease",
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.boxShadow = "0 0 0 2px var(--kodak-gold)";
        e.currentTarget.style.borderColor = "var(--kodak-gold)";
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.boxShadow = "none";
        e.currentTarget.style.borderColor = "var(--contact-border)";
      }}
    >
      <img
        src={item.url}
        alt={`Frame ${frameNumber}`}
        className="h-full w-full object-cover"
        loading="lazy"
        style={{ transform: item.rotation ? `rotate(${item.rotation}deg)` : undefined }}
      />
      {/* Frame number — contact sheet style */}
      <span
        className="absolute bottom-0 left-0 right-0 px-1.5 py-[2px] font-mono text-[9px] leading-tight"
        style={{
          color: "var(--frame-text)",
          background: "linear-gradient(transparent, rgba(234,230,223,0.92))",
        }}
      >
        {frameNumber}
      </span>
    </button>
  );
}
