# NazCast

Cast photos and videos from your iPhone to older smart TVs that can't do AirPlay —
over plain Wi-Fi, using DLNA/UPnP (what Samsung called AllShare).

- Browse your library, albums and **Shared Albums**; tap a photo and it's on the TV
- Build **collections** and play them as a looping slideshow (sort by order added, newest or oldest)
- Photos-style **drag to select** many photos at once
- **Pinch to zoom** on the phone and the TV zooms to the same spot
- Videos are converted to H.264 MP4 so older TVs can play them, with seek and volume control

Tested with a 2017 Samsung UN43MU6300. Other DLNA renderers should work too.

## How it works

The app runs a tiny HTTP server on the phone, finds the TV's media renderer, and tells it
(via UPnP AVTransport SOAP calls) to fetch and show each photo or video from that server.
Photos are re-encoded as upright JPEGs (old TVs ignore EXIF rotation and can't read HEIC).

Discovery uses SSDP multicast when available. iOS only allows multicast with an Apple-granted
entitlement, so the app also probes every address on the local /24 for Samsung's well-known
renderer description URLs over HTTP.

## Building

Requires Xcode 26+ and iOS 18+.

```sh
brew install xcodegen
cp Local.xcconfig.example Local.xcconfig   # then put your Apple Developer Team ID in it
xcodegen
open NazCast.xcodeproj
```

The app icon's donkey artwork isn't included (it's licensed art). Add your own
`Icon/NazCast.icon/Assets/donkey.svg` — a white shape on a transparent 1024×1024 canvas —
or remove the Donkey group from `Icon/NazCast.icon/icon.json`.

The first time you cast, the TV may ask you to allow the new device — accept it with the remote.
