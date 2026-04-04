import type { Metadata } from "next";
import { Barlow, Barlow_Condensed } from "next/font/google";
import "./globals.css";

const barlow = Barlow({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
  display: "swap",
  variable: "--font-barlow",
});

const barlowCondensed = Barlow_Condensed({
  subsets: ["latin"],
  weight: ["600", "700", "800"],
  display: "swap",
  variable: "--font-barlow-condensed",
});

export const metadata: Metadata = {
  title: "Charmera — Shot on Kodak",
  description: "Photos and videos from a Kodak Charmera keychain digital camera",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className={`${barlow.variable} ${barlowCondensed.variable} ${barlow.className}`}>{children}</body>
    </html>
  );
}
