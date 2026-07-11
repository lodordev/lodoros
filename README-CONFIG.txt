LODOR CARD PRE-PROVISIONING (skip the on-device setup wizard)
=============================================================

Normally the first launch of Lodor on a device runs a setup wizard
(server address -> pairing code -> device name). If you are preparing
this card for someone else, you can pair it ahead of time so the device
just works on first boot - no questions asked.

HOW

1. Copy config.json.example (next to this file, at the card root) to:

       Tools/<platform>/Lodor.pak/config.json

   <platform> is the folder under Tools/ that matches the device this
   card is for (for example my355 or h700 - look in Tools/ to see which
   platforms this card carries).

2. Edit that new config.json and fill in:

       root_uri      your RomM server address (https://...)
       token         a client token from your RomM server
       device_name   what this device should be called in RomM

   Leave the other fields as they are.

3. Put the card in the device and boot. With a valid config.json in
   place, the setup wizard is skipped and the library syncs on first
   launch.

NOTES

- config.json.example at the card root is only a template. Lodor reads
  the copy inside Tools/<platform>/Lodor.pak/ - the root file does
  nothing by itself.
- A filled-in config.json contains a live token for your server. Do not
  share or publish a card image after step 2.
- Wi-Fi can be pre-provisioned the same way: copy wifi.txt.example to
  wifi.txt at the card root and put your network on one line as
  SSID:password (details in that file).
