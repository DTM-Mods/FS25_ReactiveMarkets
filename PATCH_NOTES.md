# Reactive Markets - patch notes

## 1.4.0.0

First test build. Buyers now react to each other:

- Selling at a buyer lowers its price a little, and every other buyer of that crop raises its price a little to win your next load.
- Each buyer takes 200,000 l of a crop before its price starts to move. That allowance refills over a few days.
- After each load past the allowance, the other buyers (except the one paying most) get a small random extra, so they overtake each other in a random order.
- Limits of -15% / +15%. Prices drift back to normal over about 6 in-game days.
- New page in the ESC menu, under Production Chains: the crops you have in stock, every buyer's price, the free allowance left, a 6-month graph and sell advice (sell now / consider selling / better wait / wait).
- Multiplayer: the server works out the prices and sends them to every player. Saved with the savegame.
- Do not use together with other price mods (Market Dynamics, Dynamic Market, Volatile Economy, Supply And Demand).
