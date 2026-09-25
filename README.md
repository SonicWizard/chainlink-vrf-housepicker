# Chainlink VRF — HousePicker

A Foundry project for `HousePicker.sol`, a Chainlink VRF v2.5 consumer that rolls a
4-sided dice and maps the result to a Hogwarts house.

Based on the [Cyfrin Updraft — Chainlink Fundamentals][updraft] lesson "VRF in a smart
contract", with one bug fixed (see [Fix: house id collision](#fix-house-id-collision)).

[updraft]: https://updraft.cyfrin.io/courses/chainlink-fundamentals/chainlink-vrf/vrf-in-a-smart-contract

## Layout

- `src/` — Solidity sources
- `lib/chainlink-brownie-contracts` — Chainlink contracts, pinned at tag `1.3.0`
- `lib/forge-std` — Foundry standard library

The Remix-style import prefix `@chainlink/contracts@1.3.0/` is remapped to
`lib/chainlink-brownie-contracts/contracts/` in `foundry.toml`, so the imports work
unchanged outside Remix.

## Usage

```shell
forge build
forge test
forge fmt
```

No setup is needed for the test suite — it runs fully offline against a mocked
coordinator. For anything that touches Sepolia, `foundry.toml` defines an rpc alias
pointing at a keyless public endpoint, so `--rpc-url sepolia` works out of the box:

```shell
cast chain-id --rpc-url sepolia   # 11155111
```

Copy `.env.example` to `.env` (gitignored) to override it with your own provider, and
to set `PRIVATE_KEY` for deployments. Never put a provider URL containing an API key
in `.env.example`.

## Tests

`test/HousePicker.t.sol` deploys Chainlink's `VRFCoordinatorV2_5Mock` and repoints the
consumer at it via `setCoordinator`, so the full request/fulfill round trip is
exercised rather than stubbed. `fulfillRandomWordsWithOverride` supplies exact random
words, which makes every house outcome deterministic.

Coverage includes the house mapping for all four outcomes, the "not rolled" and "roll
in progress" guards, coordinator-only access control on the callback, event payloads,
and a fuzz test asserting that `house()` resolves for *any* random word.

Four of the tests are regression tests for the bug below and fail against the original
contract — the fuzz test finds the bad case within a handful of runs.

## Deploy

The constructor takes a funded VRF v2.5 subscription ID; the coordinator address and
key hash are hardcoded for Sepolia. `script/DeployHousePicker.s.sol` defaults to this
project's subscription and can be overridden with `VRF_SUBSCRIPTION_ID`.

```shell
cp .env.example .env   # then fill in SEPOLIA_RPC_URL and PRIVATE_KEY
forge script script/DeployHousePicker.s.sol --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" --broadcast
```

Dropping `--broadcast` simulates without sending a transaction. After deploying, add
the contract as a consumer on the subscription at <https://vrf.chain.link/sepolia>, or
`rollDice()` will revert.

## Live results on Sepolia

Three rolls against a deployed instance on Sepolia. `rollDice()` is one-shot per
address, so each roll came from a fresh wallet.

| Roll | `DiceLanded` id | `house()` |
|---|---|---|
| 1 | 1 | Gryffindor |
| 2 | 2 | Hufflepuff |
| 3 | 2 | Hufflepuff |

The first roll landed on **Gryffindor** — id `1`, precisely the outcome the original
contract could not report. Before the fix it would have stored `0` and `house()` would
have reverted with `"Dice not rolled"` until that wallet rolled again.

The second and third rolls both drew Hufflepuff from different addresses — a 1-in-4
repeat, and a useful check in its own right: identical results stored against separate
keys in `s_results` read back independently, with no interference between players.

Registering the contract as a consumer on the subscription is required before
`rollDice()` will work.

### Funding the subscription

A subscription funded with 10 LINK is **not** enough, even though a fulfillment
actually costs ~0.04 LINK. Chainlink reserves against the *gas lane's maximum* gas
price rather than the current one, and `KEY_HASH` here selects the 500 gwei lane:

```
(115,000 verification + 40,000 callback + 38,900 gasAfterPayment)
  x 500 gwei x 1.20 link premium / 5.347e15 wei-per-link  =~ 22 LINK
```

Below that the request sits in `Pending` on the subscription page and is dropped after
24 hours — it is not a stuck transaction, and it clears on its own once the balance is
topped up, with no need to roll again. Paying in native ETH (`nativePayment: true`)
avoids the LINK reserve entirely but needs a contract change.

## Fix: house id collision

The lesson's contract stores house ids as `randomWords[0] % 4`, giving the range 0–3,
while `s_results` uses `0` as its "never rolled" sentinel — the default value of an
unwritten mapping entry. Gryffindor is therefore indistinguishable from not having
rolled at all, which breaks two guards:

- `house()` reverts with `"Dice not rolled"` for a player who rolled Gryffindor. The
  result is stored but can never be read, and the revert lasts until the player rolls
  again.
- `rollDice()` gates on `s_results[msg.sender] == 0`, so that same player passes the
  "Already rolled" check and can roll again, overwriting their result.

The `% 4` also dropped the `+ 1` that the comment on that line still refers to, which
is what collapsed the ids onto the sentinel in the first place.

The fix shifts house ids to 1-based so `0` is only ever the sentinel:

| | Lesson | Here |
|---|---|---|
| House ids | `randomWords[0] % 4` → 0–3 | `(randomWords[0] % 4) + 1` → 1–4 |
| `ROLL_IN_PROGRESS` | `4` | `42` (must sit outside 1–4, since 4 is now Ravenclaw) |
| `_getHouseName` | `houseNames[id]` | `houseNames[id - 1]` |

The two `require`s in `house()` and the `== 0` guard in `rollDice()` are unchanged —
they work as written once `0` is an unambiguous sentinel.

> This is example, unaudited code. Do not use in production.
