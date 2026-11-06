# Samsung TV (local) for SmartThings

SmartThings Edge driver for Samsung Tizen TVs (2016 and later). It runs on your SmartThings hub and talks to the TV over your LAN, so no Samsung cloud, no bridge and no internet needed.

## What you get
* `switch`: on and off. Off sends the power key. On sends wake-on-LAN and, if the TV is in network standby, the power key.
* `audioVolume`: set the volume (0 to 100), volume up and down.
* `audioMute`: mute and unmute.
* `mediaInputSource`: HDMI1 to HDMI4 and TV.
* `tvChannel`: channel up and down, or a channel number.
* `refresh`
* Status (on or off, volume, mute) is polled every 10 s by default and works in routines.

## Setup
1. Give the TV a fixed IP address in your router (DHCP reservation).
2. On the TV, turn on **Settings > General > Network > Expert Settings > Power On with Mobile** (the name differs a bit per model year). Without it, the TV cannot be woken from deep standby.
3. Install the driver from the channel. In the SmartThings app, go to **Add device > Scan nearby**. Your TV is found via SSDP and added.
4. Turn the TV on. Within 2 minutes it asks to **Allow** "SmartThings Hub". Choose Allow with the remote. If you miss it, tap Refresh on the device to ask again.
5. Settings on the device:
   * **IP address**: leave on `auto` unless discovery fails.
   * **MAC address**: leave on `auto`. It is read from the TV, which gives the wifi MAC. If your TV is on a network cable, enter the MAC of the wired port for wake-on-LAN.
   * **Poll interval**: 10 s by default.

The pairing token the TV gives stays on your hub, in a device field.

## Notes
* **Status:** `http://<tv>:8001/api/v2/` gives the PowerState. A TV that does not answer counts as off.
* **Volume and mute:** UPnP RenderingControl on port 9197.
* **Keys:** remote control websocket on `wss://<tv>:8002/api/v2/channels/samsung.remote.control`. The TV uses a self-signed certificate, so it is not verified (LAN only).
* **If the TV said Deny:** go to **Settings > General > External Device Manager > Device Connection Manager > Device List**. Remove or allow "SmartThings Hub" there.
* **The input list is fixed** (HDMI1 to HDMI4, TV) because the keys are HDMI1 to HDMI4. The current input is the last one chosen through this driver.
* **Tested on:** a 2023 Neo QLED (QN900C).

## Credits
The protocols are described by [samsung-tv-ws-api](https://github.com/xchwarze/samsung-tv-ws-api) (MIT) and [ha-samsungtv-smart](https://github.com/fi-sch/ha-samsungtv-smart) (Apache 2.0). This driver is written from scratch in Lua. No code from those projects is included.

## License
Apache 2.0, see LICENSE. Not affiliated with Samsung.
