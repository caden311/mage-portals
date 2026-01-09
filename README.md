## mage-portals (WoW Classic / Anniversary realms)

Auto-invites players who ask to buy a mage portal by saying **“WTB”** and **“port”** (in any order) in:
- **/y** (Yell)
- **/1** (Channel 1, usually General)

If they include a destination keyword (like `org`), the addon will remember it and (when trade opens) show a **one-click “Cast Portal”** button.

### Install (macOS)

1. Locate your Classic Era AddOns folder (common path):
   - `~/Library/Application Support/Battle.net/World of Warcraft/_classic_era_/Interface/AddOns/`
2. Copy the folder `AnniversaryHelper` into `AddOns/` so you end up with:
   - `.../Interface/AddOns/mage-portals/mage-portals.toc`
3. Launch the game and enable the addon on the character select “AddOns” button.

### Verify it loaded

- In chat, you should see: `mage-portals: Loaded (on). Type /mp help.`
- Try:
  - `/mp help`
  - `/mp off` then reload UI (`/reload`)

### Commands

- `/mp on`: enable everything (invites + trade helpers)
- `/mp off`: disable everything
- `/mp status`: show status
- `/mp throttle N`: don’t re-invite the same player for N seconds (default 60)
- `/mp autotrade on|off`: when the invited player is in trade range, attempt to open trade automatically
- `/mp tradebutton on|off`: show a clickable “trade” button fallback (recommended to keep ON)
- `/mp portalbutton on|off`: show a clickable “cast portal” button when trade opens (recommended to keep ON)

### Auto-trade notes (important)

WoW may block fully automatic trade initiation from addons. This addon will **try** to open trade when the invitee is in range; if the client blocks it, you’ll see a **clickable button** you can press to target+trade them safely.

### Portal destination keywords

The addon recognizes these destinations (case-insensitive):
- **Orgrimmar**: `org`, `orgrimmar` → casts `Portal: Orgrimmar`
- **Thunder Bluff**: `tb`, `thunderbluff`, `thunder bluff` → casts `Portal: Thunder Bluff`
- **Undercity**: `uc`, `undercity` → casts `Portal: Undercity`
- **Shattrath**: `shat`, `shatt`, `shattrath` → casts `Portal: Shattrath`

### Portal casting note (important)

WoW generally blocks **fully automatic spell casting** from addons. When trade opens, `mage-portals` shows a **clickable button** to cast the requested portal reliably.

### Notes

- The TOC `## Interface:` value may need updating after patches. If the addon shows as “Out of Date”, either check “Load out of date AddOns” or bump the number in `mage-portals/mage-portals.toc`.


# mage-portals
