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
3. Install the driver from the channel. In the SmartThings app, go to **Add device > Scan nearby**. Your TV is found via SSDP, or by a quick scan of port 8001 on your network when SSDP gets no answer. Scanning again never adds a TV twice: a TV you already have (also one you set up by IP address) is recognised by its IP or MAC address.
4. Turn the TV on. Within 2 minutes it asks to **Allow** "SmartThings Hub". Choose Allow with the remote. If you miss it, tap Refresh on the device to ask again.
5. Settings on the device:
   * **IP address**: leave on `auto` unless discovery fails.
   * **MAC address**: leave on `auto`. It is read from the TV, which gives the wifi MAC. If your TV is on a network cable, enter the MAC of the wired port for wake-on-LAN.
   * **Poll interval**: 10 s by default.
   * **Sound output**: choose **Soundbar or receiver** when the sound goes over HDMI ARC/eARC. Volume and mute then go as remote control keys, which the TV passes on to the soundbar. The soundbar volume can not be read, so the volume shown is counted from the last value set (a change with the soundbar's own remote is not seen).

The pairing token the TV gives stays on your hub, in a device field.

## Notes
* **Status:** `http://<tv>:8001/api/v2/` gives the PowerState. A TV that does not answer counts as off.
* **Volume and mute:** UPnP RenderingControl on port 9197.
* **Keys:** remote control websocket on `wss://<tv>:8002/api/v2/channels/samsung.remote.control`. The TV uses a self-signed certificate, so it is not verified (LAN only).
* **If the TV said Deny:** go to **Settings > General > External Device Manager > Device Connection Manager > Device List**. Remove or allow "SmartThings Hub" there.
* **Input and channel start with a value** (the last input chosen through the driver, otherwise TV): the TV does not report them over the LAN, and the app greys out a control that never had a value.
* **Sources by name:** the Source list shows your own names (setting **Sources**, e.g. `Tv=1,PC=3,Sonos Beam=5`). A number is the tile in the TV's Source menu (left to right, top to bottom); the driver opens the menu, goes to the top left tile and on to that tile. Newer TVs (2021 and later) ignore the HDMI1..4 keys, so this works where direct keys do not. A key sequence (`PC=KEY_HDMI1`) is sent as it is. "auto" gives TV and HDMI 1 to 4 (Source menu for 2021 and later, direct keys before). The **Source menu** row (custom capability `silvervalley08660.tvSourceMenu`) opens the menu itself and shows Open for a few seconds. Uses the custom capability `silvervalley08660.tvInput`.
* **Remote keys:** arrows, OK, back, exit, menu, settings, home and numbers (keypadInput). In a routine, "set channel" also takes a key sequence such as `KEY_SOURCE+800+KEY_RIGHT+KEY_ENTER` (pauses in ms).
* **The remote control channel stays open** between commands and closes after 2 minutes without keys, so keys go through without delay.
* **The input list is fixed** (HDMI1 to HDMI4, TV) because the keys are HDMI1 to HDMI4. The current input is the last one chosen through this driver.
* **Events:** a value only goes to the hub when it changed; after a driver start every value is sent once so the app catches up (re-emitting unchanged values makes the hub drop events of a device).
* **Tested on:** a 2023 Neo QLED (QN900C).

## Credits
The protocols are described by [samsung-tv-ws-api](https://github.com/xchwarze/samsung-tv-ws-api) (MIT) and [ha-samsungtv-smart](https://github.com/fi-sch/ha-samsungtv-smart) (Apache 2.0). This driver is written from scratch in Lua. No code from those projects is included.

**Security (build 2026-11-09b):** the TV's self-signed certificate is pinned when the token is first used. Another certificate later (TV reset, or another device at the TV's address): the token is not sent, the driver forgets it and the TV asks Allow again.

## License
Apache 2.0, see LICENSE. Not affiliated with Samsung.
