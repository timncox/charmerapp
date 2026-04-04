import { Header } from "@/components/Header";
import { ContactSheet } from "@/components/ContactSheet";
import { Footer } from "@/components/Footer";
import { fetchMediaList } from "@/lib/media";

export const dynamic = "force-dynamic";

export default async function Home() {
  const items = await fetchMediaList();

  return (
    <main className="min-h-screen flex flex-col" style={{ background: "var(--kodak-cream)" }}>
      <Header />
      <div className="flex-1">
        <ContactSheet items={items} />
      </div>
      <Footer items={items} />
    </main>
  );
}
