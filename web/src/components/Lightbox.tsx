"use client";

import { useEffect, useCallback, useState } from "react";
import type { MediaItem } from "@/lib/media";

interface LightboxProps {
  items: MediaItem[];
  currentIndex: number;
  onClose: () => void;
  onNavigate: (index: number) => void;
  onDelete: (index: number) => void;
}

export function Lightbox({ items, currentIndex, onClose, onNavigate, onDelete }: LightboxProps) {
  const item = items[currentIndex];
  const [rotation, setRotation] = useState(item.rotation || 0);
  const [isDeleting, setIsDeleting] = useState(false);

  const handleDelete = useCallback(() => {
    if (isDeleting) return;
    if (!confirm("Delete this photo?")) return;
    setIsDeleting(true);
    fetch("/api/delete", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: item.url }),
    })
      .then((res) => res.json())
      .then(() => {
        onDelete(currentIndex);
      })
      .catch(() => {
        setIsDeleting(false);
      });
  }, [item.url, currentIndex, onDelete, isDeleting]);

  // Reset rotation when navigating to a different item
  useEffect(() => {
    setRotation(items[currentIndex]?.rotation || 0);
  }, [currentIndex, items]);

  const handleRotate = useCallback(() => {
    const newRotation = (rotation + 90) % 360;
    setRotation(newRotation);
    // Persist rotation via API in background
    fetch("/api/rotate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: item.url, degrees: 90 }),
    }).catch(() => {
      // Revert on failure
      setRotation(rotation);
    });
  }, [rotation, item.url]);

  const goNext = useCallback(() => {
    if (currentIndex < items.length - 1) onNavigate(currentIndex + 1);
  }, [currentIndex, items.length, onNavigate]);

  const goPrev = useCallback(() => {
    if (currentIndex > 0) onNavigate(currentIndex - 1);
  }, [currentIndex, onNavigate]);

  useEffect(() => {
    function handleKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowRight") goNext();
      if (e.key === "ArrowLeft") goPrev();
    }
    window.addEventListener("keydown", handleKey);
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", handleKey);
      document.body.style.overflow = "";
    };
  }, [onClose, goNext, goPrev]);

  const frameNumber = item.filename.replace(/^(PICT|MOVI)/, "").replace(/\.\w+$/, "");
  const date = new Date(item.timestamp);
  const dateStr = date.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  const timeStr = date.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      style={{
        background: "rgba(8, 6, 3, 0.96)",
        animation: "lightbox-fade-in 0.2s ease-out",
      }}
      onClick={onClose}
    >
      {/* Close button */}
      <button
        onClick={onClose}
        className="absolute right-4 top-4 z-10 flex h-8 w-8 items-center justify-center rounded-full text-white/50 hover:text-white hover:bg-white/10"
        style={{ transition: "all 0.15s ease" }}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <line x1="3" y1="3" x2="13" y2="13" />
          <line x1="13" y1="3" x2="3" y2="13" />
        </svg>
      </button>

      {/* Nav — previous */}
      {currentIndex > 0 && (
        <button
          onClick={(e) => { e.stopPropagation(); goPrev(); }}
          className="absolute left-3 top-1/2 -translate-y-1/2 z-10 flex h-10 w-10 items-center justify-center rounded-full text-white/30 hover:text-white hover:bg-white/10"
          style={{ transition: "all 0.15s ease" }}
        >
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="12 4 6 10 12 16" />
          </svg>
        </button>
      )}

      {/* Nav — next */}
      {currentIndex < items.length - 1 && (
        <button
          onClick={(e) => { e.stopPropagation(); goNext(); }}
          className="absolute right-3 top-1/2 -translate-y-1/2 z-10 flex h-10 w-10 items-center justify-center rounded-full text-white/30 hover:text-white hover:bg-white/10"
          style={{ transition: "all 0.15s ease" }}
        >
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="8 4 14 10 8 16" />
          </svg>
        </button>
      )}

      {/* Image / Video */}
      <div
        className="max-h-[85vh] max-w-[90vw]"
        style={{ animation: "lightbox-image-in 0.2s ease-out" }}
        onClick={(e) => e.stopPropagation()}
      >
        {item.type === "video" ? (
          <video
            src={item.url}
            controls
            autoPlay
            muted
            playsInline
            className="max-h-[85vh] max-w-[90vw] object-contain rounded-sm"
            style={{ boxShadow: "0 4px 40px rgba(0,0,0,0.5)" }}
          />
        ) : (
          <img
            src={item.url}
            alt={`Frame ${frameNumber}`}
            className="max-h-[85vh] max-w-[90vw] object-contain rounded-sm"
            style={{
              boxShadow: "0 4px 40px rgba(0,0,0,0.5)",
              transform: rotation ? `rotate(${rotation}deg)` : undefined,
              transition: "transform 0.3s ease",
            }}
          />
        )}
      </div>

      {/* Bottom info bar */}
      <div
        className="absolute bottom-0 left-0 right-0 flex items-center justify-center gap-2 py-3 font-mono text-[11px]"
        style={{
          background: "linear-gradient(transparent, rgba(0,0,0,0.6))",
          color: "rgba(255,255,255,0.45)",
        }}
      >
        <span style={{ color: "var(--kodak-gold)", opacity: 0.7 }}>{item.filename}</span>
        <span>&middot;</span>
        <span>{dateStr}</span>
        <span>&middot;</span>
        <span>{timeStr}</span>
        {item.type === "photo" && (
          <>
            <span>&middot;</span>
            <button
              onClick={(e) => { e.stopPropagation(); handleRotate(); }}
              className="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-white/40 hover:text-white hover:bg-white/10"
              style={{ transition: "all 0.15s ease", fontSize: "13px", lineHeight: 1 }}
              title="Rotate 90° clockwise"
            >
              ↻
            </button>
          </>
        )}
        <span>&middot;</span>
        <button
          onClick={(e) => { e.stopPropagation(); handleDelete(); }}
          className="inline-flex items-center justify-center rounded px-1.5 py-0.5 text-red-400/60 hover:text-red-400 hover:bg-red-400/10"
          style={{ transition: "all 0.15s ease", fontSize: "11px", lineHeight: 1 }}
          title="Delete"
          disabled={isDeleting}
        >
          {isDeleting ? "..." : "✕"}
        </button>
        <span className="ml-2 text-[10px] text-white/25">{currentIndex + 1}/{items.length}</span>
      </div>
    </div>
  );
}
