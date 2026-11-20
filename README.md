# Reactive Markets (FS25)

Author: PropaineX

Buyers react to each other. When you sell at a buyer, that buyer's price for the crop dips a little, and every
other buyer of that crop raises its price a little to win the next load. Prices drift back to normal over a few
in-game days. Seasons and great demand still work as normal on top.

## ⚠ Do not use with other price mods

Do **not** run Reactive Markets together with any of these mods:

- **Market Dynamics** (TisonK)
- **Dynamic Market** (Nalathan)
- **Volatile Economy** (NoticeGG)
- **Supply And Demand** (bwibble)

They change the same selling prices, so the results will clash: prices can stack up, jump, or not match what you
are paid. The same goes for any other mod that changes selling prices.

## How it works

- Each buyer takes **200,000 l** of a crop before its price starts to move (this allowance refills over a few days).
- Past that, about **-2%** at that buyer and **+1%** at every rival buyer of that crop per 120,000 l sold.
- Hard limits of -15% / +15%, with smaller steps near the limits.
- Prices recover over about **6 in-game days**.
- Saved with the savegame.
- Multiplayer: the server works out the prices and sends them to every player.

## Settings

`modSettings/FS25_ReactiveMarkets.xml` (created on first start from the mod's `settings.xml`). Edit that copy; it is
read when a savegame loads. If you update from an older version, delete it so the new defaults are copied in.

## Console

- `rmShow [fillType]` lists each buyer's current price factor (e.g. `rmShow BARLEY`).
- `rmReset` resets every buyer to normal (server / host only).
