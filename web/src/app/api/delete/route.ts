import { NextRequest, NextResponse } from "next/server";
import { del, put, list } from "@vercel/blob";

export async function POST(request: NextRequest) {
  const { url } = await request.json();
  if (!url) {
    return NextResponse.json({ error: "Missing url" }, { status: 400 });
  }

  // Delete the blob
  try {
    await del(url);
  } catch {
    // Blob may already be gone, continue to remove from metadata
  }

  // Remove from metadata
  const { blobs } = await list({ prefix: "charmera-metadata.json" });
  if (blobs.length === 0) {
    return NextResponse.json({ error: "No metadata found" }, { status: 404 });
  }

  const metaResponse = await fetch(blobs[0].url, { cache: "no-store" });
  const items = await metaResponse.json();
  const updated = items.filter((item: { url: string }) => item.url !== url);

  await put("charmera-metadata.json", JSON.stringify(updated, null, 2), {
    access: "public",
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: "application/json",
  });

  return NextResponse.json({ success: true, remaining: updated.length });
}
