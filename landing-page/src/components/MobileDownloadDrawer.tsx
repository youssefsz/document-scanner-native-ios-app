import { useState } from "react"

import {
  Drawer,
  DrawerClose,
  DrawerContent,
  DrawerDescription,
  DrawerTitle,
  DrawerTrigger,
} from "@/components/ui/drawer"

interface MobileDownloadDrawerProps {
  appName: string
  appStoreUrl: string
  assetBaseUrl: string
}

export function MobileDownloadDrawer({
  appName,
  appStoreUrl,
  assetBaseUrl,
}: MobileDownloadDrawerProps) {
  const [open, setOpen] = useState(false)

  return (
    <div className="mobile-download">
      <Drawer
        open={open}
        onOpenChange={setOpen}
        showSwipeHandle
        swipeDirection="down"
      >
        <DrawerTrigger
          render={
            <button
              className="mobile-download__trigger"
              type="button"
              aria-label={
                open ? "Close download drawer" : `Download ${appName}`
              }
              data-open={open}
            />
          }
        >
          <span className="mobile-menu-icon" aria-hidden="true">
            <span></span>
            <span></span>
            <span></span>
          </span>
        </DrawerTrigger>

        <DrawerContent className="mobile-drawer__content">
          <DrawerClose
            className="mobile-drawer__close"
            type="button"
            aria-label="Close download drawer"
          >
            <span aria-hidden="true"></span>
          </DrawerClose>
          <div className="mobile-drawer__body">
            <div className="mobile-drawer__icon-wrap">
              <img
                className="mobile-drawer__icon"
                src={`${assetBaseUrl}icons/icon-512.png`}
                alt=""
                width="88"
                height="88"
              />
            </div>
            <p className="eyebrow">DocScanner for iPhone and iPad</p>
            <DrawerTitle className="mobile-drawer__title">
              Scan paper. Keep files private.
            </DrawerTitle>
            <DrawerDescription className="mobile-drawer__description">
              Download {appName} from the App Store.
            </DrawerDescription>
            <a
              className="store-badge"
              href={appStoreUrl}
              target="_blank"
              rel="noopener noreferrer"
              aria-label={`Download ${appName} on the App Store`}
            >
              <img
                src={`${assetBaseUrl}download-black.svg`}
                width="120"
                height="40"
                alt=""
                decoding="async"
              />
            </a>
          </div>
        </DrawerContent>
      </Drawer>
    </div>
  )
}
