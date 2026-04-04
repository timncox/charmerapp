import { NextRequest, NextResponse } from "next/server";
import { put, list } from "@vercel/blob";

export async function POST(request: NextRequest) {
  const { url, degrees } = await request.json();
  if (!url || !degrees) {
    return NextResponse.json({ error: "Missing url or degrees" }, { status: 400 });
  }

  // Update metadata JSON to add rotation
  const { blobs } = await list({ prefix: "charmera-metadata.json" });
  if (blobs.length === 0) {
    return NextResponse.json({ error: "No metadata found" }, { status: 404 });
  }

  const metaResponse = await fetch(blobs[0].url, { cache: "no-store" });
  const items = await metaResponse.json();

  const updated = items.map((item: Record<string, unknown>) => {
    if (item.url === url) {
      const currentRotation = (item.rotation as number) || 0;
      return { ...item, rotation: (currentRotation + degrees) % 360 };
    }
    return item;
  });

  await put("charmera-metadata.json", JSON.stringify(updated, null, 2), {
    access: "public",
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: "application/json",
  });

  return NextResponse.json({ success: true });
}
