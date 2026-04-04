import { put, list } from "@vercel/blob";

export interface MediaItem {
  url: string;
  type: "photo" | "video";
  timestamp: string; // ISO 8601
  hash: string; // SHA-256
  filename: string; // e.g. PICT0001.jpg or MOVI0020.mp4
  rotation?: number; // degrees clockwise (0, 90, 180, 270)
}

const METADATA_PATH = "charmera-metadata.json";

export async function fetchMediaList(): Promise<MediaItem[]> {
  const { blobs } = await list({ prefix: METADATA_PATH });
  if (blobs.length === 0) return [];

  const metadataBlob = blobs[0];
  const response = await fetch(metadataBlob.url, { cache: "no-store" });
  if (!response.ok) return [];

  const items: MediaItem[] = await response.json();
  // Newest first
  return items.sort(
    (a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime()
  );
}

export async function appendMedia(newItems: MediaItem[]): Promise<MediaItem[]> {
  const existing = await fetchMediaList();

  // Deduplicate by hash
  const existingHashes = new Set(existing.map((item) => item.hash));
  const unique = newItems.filter((item) => !existingHashes.has(item.hash));
  if (unique.length === 0) return existing;

  const updated = [...existing, ...unique];

  await put(METADATA_PATH, JSON.stringify(updated, null, 2), {
    access: "public",
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: "application/json",
  });

  return updated;
}
