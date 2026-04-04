"use client";

import { useState } from "react";
import type { MediaItem } from "@/lib/media";
import { MediaTile } from "./MediaTile";
import { Lightbox } from "./Lightbox";

interface ContactSheetProps {
  items: MediaItem[];
}

export function ContactSheet({ items: initialItems }: ContactSheetProps) {
  const [items, setItems] = useState(initialItems);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  const handleDelete = (index: number) => {
    const newItems = items.filter((_, i) => i !== index);
    setItems(newItems);
    if (newItems.length === 0) {
      setLightboxIndex(null);
    } else if (index >= newItems.length) {
      setLightboxIndex(newItems.length - 1);
    }
  };

  if (items.length === 0) {
    return (
      <div className="flex min-h-[50vh] items-center justify-center text-gray-400">
        No photos yet. Connect your Charmera and click import.
      </div>
    );
  }

  return (
    <>
      <div
        className="grid grid-cols-2 gap-[3px] p-3 sm:grid-cols-3 sm:gap-[4px] sm:p-4 md:grid-cols-4 lg:grid-cols-5"
        style={{
          background: "var(--grid-bg)",
          boxShadow: "inset 0 1px 3px rgba(0,0,0,0.06)",
        }}
      >
        {items.map((item, i) => (
          <MediaTile key={item.hash} item={item} index={i} onClick={() => setLightboxIndex(i)} />
        ))}
      </div>

      {lightboxIndex !== null && (
        <Lightbox
          items={items}
          currentIndex={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
          onNavigate={setLightboxIndex}
          onDelete={handleDelete}
        />
      )}
    </>
  );
}
