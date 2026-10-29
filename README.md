# Creality K2 Pro camera for Mainsail

Adds a working live camera feed to the **Mainsail** web interface of a Creality
K2 Pro, using the printer's built-in camera.

Mainsail runs on the printer at `http://<printer>:4408/`, but out of the box its
camera panel shows nothing useful. This plugin fixes that.

## Why the stock camera panel does not work

The K2 Pro camera is **WebRTC only**. There is no MJPEG, RTSP or JPEG endpoint
anywhere on the printer. Moonraker advertises the camera as an `iframe` pointing
at Creality's `/camera.html`, and that page speaks a non-standard WebRTC dialect:

- The printer sends **two `a=fmtp` lines for one payload**, so the second
  overwrites `packetization-mode` and `profile-level-id`.
- Generic WebRTC clients complete **ICE** and then stall forever at **DTLS**.

Browsers and ordinary libraries therefore cannot display the stream directly.
The fix is to put a relay in between that understands the dialect: **go2rtc**,
which has native support for Creality cameras.

```
Browser ──WebRTC──> go2rtc (on printer) ──WebRTC/Creality──> cam_app ──> camera
             │
        Mainsail webrtc-go2rtc player
```

## Requirements

- Creality K2 Pro (or another K2-series printer whose camera lives on port 8000)
- **Root SSH access** to the printer — enable it in the printer's settings
- Mainsail with the `WebRTC (go2rtc)` player (tested on v2.13.2)
- `curl` and `scp` on the computer you run the installer from

The printer itself needs no internet access: the installer downloads the binary
on your computer and copies it over.

## Install

```bash
git clone https://github.com/kkazakov/creality-k2-pro-camera-plugin.git
cd creality-k2-pro-camera-plugin
./install.sh 192.168.1.50          # your printer's address
```

You will be prompted for the printer's root password. The script:

1. downloads `go2rtc` for ARMv7 and copies it to `/mnt/UDISK/go2rtc/`
2. writes a configuration that relays the printer's own WebRTC stream
3. installs and enables an OpenWrt service (`/etc/init.d/go2rtc`)
4. verifies the relay produces a frame before continuing
5. registers the webcam in Moonraker — stored in its **database**, so it
   survives firmware updates
6. comments out the stock `iframe` webcam entry, which would otherwise show a
   second, permanently blank panel

Then open `http://<printer>:4408/` and expand the **Webcam** panel.

## Verify

```bash
# does the relay produce a still?
curl -s -o frame.jpg "http://192.168.1.50:1984/api/frame.jpeg?src=k2pro"

# is the webcam registered?
curl -s http://192.168.1.50:7125/server/webcams/list
```

`/api/frame.jpeg` is also handy on its own — it is a plain JPEG of the current
view and works from any script.

## Configuration

Everything lives in `/mnt/UDISK/go2rtc/go2rtc.yaml`:

```yaml
api:
  listen: ":1984"
  origin: "*"               # Mainsail's player uses a cross-origin WebSocket

webrtc:
  listen: ":8555"
  candidates:
    - 192.168.1.50:8555     # printer LAN address

streams:
  k2pro: webrtc:http://127.0.0.1:8000/call/webrtc_local#format=creality
```

The `#format=creality` suffix is required — without it go2rtc will not negotiate
with this firmware.

The `candidates` entry must be the printer's LAN address, otherwise browsers
receive unreachable ICE candidates. The installer fills this in for you.

Restart after editing:

```bash
/etc/init.d/go2rtc restart
```

## What survives a firmware update

| Path | Survives update | Contains |
| --- | --- | --- |
| `/mnt/UDISK/go2rtc/` | yes | binary and configuration |
| Moonraker database | yes | the webcam entry |
| `/etc/init.d/go2rtc` | **no** | service definition |
| `/usr/share/moonraker/moonraker.conf` | **no** | stock iframe webcam (reverts) |

After a firmware update the service definition is gone, so re-run `./install.sh`.
The binary, its configuration and the webcam entry are already in place; the
script is idempotent and simply re-installs the service.

## Uninstall

```bash
./uninstall.sh 192.168.1.50
```

Stops and disables the service, removes `/mnt/UDISK/go2rtc`, deletes the webcam
entry and restores the original `moonraker.conf` from the backup taken at
install time.

## Remote access (HTTPS / VPN)

If you open Mainsail through a hostname such as `https://k2.example.com`, the
player derives its WebSocket from `stream_url` and inherits the page's scheme.
A LAN IP in `stream_url` therefore becomes `wss://192.168.88.86:1984`, which
fails: the address is not reachable from outside, and go2rtc does not speak TLS.

Serve go2rtc under the same origin as Mainsail. Add this to the printer's
`/etc/nginx/nginx.conf`, inside the `server` block (the file already defines
`$connection_upgrade`):

```nginx
location /go2rtc/ {
    proxy_pass http://127.0.0.1:1984/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $http_host;
    proxy_read_timeout 86400;
}
```

Then register a webcam entry that uses the public URL:

| Field | Value |
| --- | --- |
| service | `webrtc-go2rtc` |
| stream_url | `https://k2.example.com/go2rtc/stream.html?src=k2pro&mode=webrtc` |
| snapshot_url | `https://k2.example.com/go2rtc/api/frame.jpeg?src=k2pro` |

Your outer reverse proxy must forward `/go2rtc/` too, with WebSocket upgrade.
Check it with `curl -sI https://k2.example.com/go2rtc/api/streams` — it should
not redirect.

### Media path

WebRTC media does not travel through the proxy: the browser connects directly to
the printer's ICE candidates on port 8555. That works on the LAN and over a VPN
that routes to the printer. From the open internet you need one of:

- forward `8555` TCP **and** UDP to the printer and advertise a public candidate
  (`webrtc.candidates`), or
- use HLS through the proxy, which needs no extra ports and no transcoding:
  `https://k2.example.com/go2rtc/api/stream.m3u8?src=k2pro` with service
  `hlsstreamer` (adds a few seconds of latency).

## Troubleshooting

**Player says "Disconnected".** The `api.origin` setting is missing, so go2rtc
rejects the cross-origin WebSocket from Mainsail's player. It must be present:

```yaml
api:
  listen: ":1984"
  origin: "*"
```

**Panel is black.** Reload Mainsail once. The browser has to complete the WebRTC
handshake, and the first frame can take a second or two. Check the relay first
with the `curl` command above — if that returns a JPEG, the printer side is fine.

**Two camera panels.** The stock iframe entry was not disabled. Run
`grep -n "webcam" /usr/share/moonraker/moonraker.conf`, comment out the block,
and restart Moonraker.

**Service will not start.** Run it in the foreground to see the error:

```bash
/mnt/UDISK/go2rtc/go2rtc -config /mnt/UDISK/go2rtc/go2rtc.yaml
```

**Nothing listens on 1984.** Confirm the service is enabled:
`/etc/init.d/go2rtc status`.

**Camera view is very dark.** The chamber light (`output_pin LED`) is off. Turn
it on with `SET_PIN PIN=LED VALUE=1` via the Moonraker console.

## Tested on

| Component | Version |
| --- | --- |
| Printer | Creality K2 Pro, firmware `v1.1.260206` |
| OS | OpenWrt 21.02, Linux 5.4.61, armv7l |
| Moonraker | 1.4.0 |
| Mainsail | 2.13.2 |
| go2rtc | 1.9.15 |

## Notes

- The relay adds no transcoding: go2rtc passes the printer's H.264 through, so
  CPU load on the printer is minimal.
- Ports `1984` (HTTP API) and `8555` (WebRTC) are opened on the printer and
  listen on all interfaces. Do not expose them to the internet.
- This project is unaffiliated with Creality. Modifying your printer is at your
  own risk.

## License

MIT — see [LICENSE](LICENSE).
