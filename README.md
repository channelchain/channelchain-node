# channelchain-node

Chain node implementation for [ChannelChain](https://channelchain.net), a permanent anonymous BBS. This is a fork of [Arweave](https://github.com/ArweaveTeam/arweave) with custom modifications for the BBS use case.

> **Status: under active development.** This repository is currently public during development. Production deployment, third-party mining, and public APIs are not yet supported. The interfaces and storage format may change.

This repository is consumed as a git submodule by the (private) `channelchain/channelchain` repository.

## ChannelChain modifications

- **RandomX fork mechanism** — switch from a SHA256 stub to real RandomX at a configured block height without invalidating earlier blocks (`ar_fork:height_randomx_switch/0`)
- **BBS-aware TX validation** — `ar_bbs_validator.erl` enforces board / thread / post invariants at the chain level
- **Per-board configuration & PoW coefficients** — `Board-Config` TXs store per-board settings
- **Three-tier permissions** — Admin / Moderator / Board Moderator
- **TX rewrite protocol** — two-step propose-then-commit replacement of posts (used for moderator deletes that preserve thread numbering)
- **Genesis-based admin distribution** — admin / moderator addresses baked into the genesis block at startup

## Architecture

|                   | Upstream Arweave            | ChannelChain                                                             |
| ----------------- | --------------------------- | ------------------------------------------------------------------------ |
| Base              | Erlang/OTP 26 + RandomX NIF | same                                                                     |
| Network name      | `arweave.N.1`               | `channelchain.mainnet.1`                                                 |
| Genesis           | open join                   | admin / moderator addresses baked in                                     |
| TX types          | data store                  | + Board / Thread / Post / Admin-* / Board-Config / Profile / Report etc. |
| Mining            | SPoRA                       | SPoRA + AR_TEST lightweight parameters                                   |
| Consensus changes | —                           | RandomX fork mechanism, BBS validator                                    |

## Relationship to upstream

This fork tracks upstream [ArweaveTeam/arweave](https://github.com/ArweaveTeam/arweave) and rebases / cherry-picks from it as needed. The ChannelChain-specific delta is kept as small as practical.

## License

Inherits the GNU General Public License v2.0 from Arweave. See [LICENSE.md](LICENSE.md). ChannelChain-specific modifications are released under the same terms.
