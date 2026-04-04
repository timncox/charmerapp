import { NextRequest, NextResponse } from "next/server";
import { appendMedia, type MediaItem } from "@/lib/media";

export async function POST(request: NextRequest) {
  const secret = process.env.IMPORT_SECRET;
  const auth = request.headers.get("authorization");

  if (!secret || auth !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await request.json();

  if (!Array.isArray(body.items)) {
    return NextResponse.json(
      { error: "Expected { items: MediaItem[] }" },
      { status: 400 }
    );
  }

  const items: MediaItem[] = body.items;
  const updated = await appendMedia(items);

  return NextResponse.json({
    added: items.length,
    total: updated.length,
  });
}
