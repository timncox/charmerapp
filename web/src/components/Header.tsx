import Image from "next/image";

export function Header() {
  return (
    <header>
      {/* Gold nav bar */}
      <div
        className="flex items-center gap-3 px-5 py-3"
        style={{
          background: "linear-gradient(180deg, #ffc420 0%, var(--kodak-gold) 100%)",
        }}
      >
        <Image
          src="/kodak-logo.png"
          alt="Kodak"
          width={40}
          height={36}
          className="rounded-sm"
          style={{ filter: "drop-shadow(0 1px 2px rgba(0,0,0,0.15))" }}
        />
        <div className="leading-tight">
          <div
            className="text-[17px] font-extrabold tracking-wide"
            style={{
              color: "var(--kodak-red)",
              textShadow: "0 1px 0 rgba(255,255,255,0.3)",
              fontFamily: "var(--font-barlow-condensed), sans-serif",
            }}
          >
            KODAK
          </div>
          <div
            className="text-[11px] font-medium tracking-[0.25em] text-black/60"
            style={{ fontStyle: "italic" }}
          >
            Charmera
          </div>
        </div>
        <div className="ml-auto text-[10px] font-semibold tracking-[0.15em] text-black/35 hidden sm:block uppercase">
          Keychain Digital Camera
        </div>
      </div>

      {/* Rainbow stripes — thicker, like the packaging band */}
      <div className="flex h-[5px]">
        <div className="flex-1" style={{ background: "var(--kodak-red)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-orange)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-amber)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-gold)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-green)" }} />
        <div className="flex-1" style={{ background: "var(--kodak-blue)" }} />
      </div>
    </header>
  );
}
