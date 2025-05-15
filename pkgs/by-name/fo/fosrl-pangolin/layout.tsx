import type { Metadata } from "next";
import "./globals.css";
import { Inter } from "next/font/google";
import { Toaster } from "@/components/ui/toaster";
import { ThemeProvider } from "@app/providers/ThemeProvider";
import EnvProvider from "@app/providers/EnvProvider";
import { pullEnv } from "@app/lib/pullEnv";
import SupportStatusProvider from "@app/providers/SupporterStatusProvider";
import { priv } from "@app/lib/api";
import { AxiosResponse } from "axios";
import { IsSupporterKeyVisibleResponse } from "@server/routers/supporterKey";
import LicenseStatusProvider from "@app/providers/LicenseStatusProvider";
import { GetLicenseStatusResponse } from "@server/routers/license";
import LicenseViolation from "./components/LicenseViolation";
import { cache } from "react";

export const metadata: Metadata = {
    title: `Dashboard - Pangolin`,
    description: ""
};

export const dynamic = "force-dynamic";

// const font = Figtree({ subsets: ["latin"] });
const font = Inter({ subsets: ["latin"] });

export default async function RootLayout({
    children
}: Readonly<{
    children: React.ReactNode;
}>) {
    const env = pullEnv();

    let supporterData = {
        visible: true
    } as any;

    const res = await priv.get<AxiosResponse<IsSupporterKeyVisibleResponse>>(
        "supporter-key/visible"
    );
    supporterData.visible = res.data.data.visible;
    supporterData.tier = res.data.data.tier;

    const licenseStatusRes = await cache(
        async () =>
            await priv.get<AxiosResponse<GetLicenseStatusResponse>>(
                "/license/status"
            )
    )();
    const licenseStatus = licenseStatusRes.data.data;

    return (
        <html suppressHydrationWarning>
            <body className={`${font.className} h-screen overflow-hidden`}>
                <ThemeProvider
                    attribute="class"
                    defaultTheme="system"
                    enableSystem
                    disableTransitionOnChange
                >
                    <EnvProvider env={pullEnv()}>
                        <LicenseStatusProvider licenseStatus={licenseStatus}>
                            <SupportStatusProvider
                                supporterStatus={supporterData}
                            >
                                {/* Main content */}
                                <div className="h-full flex flex-col">
                                    <div className="flex-1 overflow-auto">
                                        <LicenseViolation />
                                        {children}
                                    </div>
                                </div>
                            </SupportStatusProvider>
                        </LicenseStatusProvider>
                    </EnvProvider>
                    <Toaster />
                </ThemeProvider>
            </body>
        </html>
    );
}
