## mage-portals (WoW Classic / Anniversary realms)

Auto-invites players who ask to buy a mage portal by saying **“WTB”** and **“port”** (in any order) in:
- **/y** (Yell)
- **/s** (Say)
- **Whispers**
- **/1** (Channel 1, usually General)
- **/2** (Trade) *(optional; `/mp ch2 on`)*

### Install (macOS)

1. Locate your Classic Era AddOns folder (common path):
   - `~/Library/Application Support/Battle.net/World of Warcraft/_classic_era_/Interface/AddOns/`
2. Copy the folder `mage-portals` into `AddOns/` so you end up with:
   - `.../Interface/AddOns/mage-portals/mage-portals.toc`
3. Launch the game and enable the addon on the character select “AddOns” button.

### Verify it loaded

- In chat, you should see: `mage-portals: Loaded (on). Type /mp help.`
- Try:
  - `/mp help`
  - `/mp off` then reload UI (`/reload`)

### Commands

- `/mp on`: enable addon (auto-invite on)
- `/mp off`: disable addon (stops invites)
- `/mp status`: show status
- `/mp throttle N`: don’t re-invite the same player for N seconds (default 60)
- `/mp ch2 on|off`: also listen in /2 (Trade) (default off)
- `/mp water on|off`: also invite people asking for mage water (default off)
- `/mp minimap on|off`: show/hide the minimap icon (you can also right-click the icon to hide it)
- `/mp whisper on|off`: whisper the invitee a confirmation / destination message
- `/mp debug off|on|0|1|2`: debug logging (0=off, 1=basic, 2=verbose)
- `/mp testinvite Name`: manually attempt an invite (debug helper)

### Defaults

By default, **only auto-invite is enabled**.

### Portal destination keywords

The addon recognizes these destinations (case-insensitive):
- **Orgrimmar**: `org`, `orgrimmar` → casts `Portal: Orgrimmar`
- **Thunder Bluff**: `tb`, `thunderbluff`, `thunder bluff` → casts `Portal: Thunder Bluff`
- **Undercity**: `uc`, `undercity` → casts `Portal: Undercity`
- **Shattrath**: `shat`, `shatt`, `shattrath` → casts `Portal: Shattrath`
- **Silvermoon**: `sm`, `silvermoon` → casts `Portal: Silvermoon`

### Portal casting note (important)

WoW generally blocks **fully automatic spell casting** from addons.

### Notes

- The TOC `## Interface:` value may need updating after patches. If the addon shows as “Out of Date”, either check “Load out of date AddOns” or bump the number in `mage-portals/mage-portals.toc`.


# mage-portals
