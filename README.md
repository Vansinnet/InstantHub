# InstantHub

A Darktide Mod Framework mod that reduces transition work by preloading and retaining Mourningstar, operative, UI, and Meat Grinder resources and can reserve or preconnect to a preferred Mourningstar region.

## Installation

Install DMF, place the `InstantHub` folder in Darktide's mods directory, and add `InstantHub` to `mod_load_order.txt`.

## Download

Download `InstantHub.zip` from the [latest GitHub release](../../releases/latest). Do not use GitHub's source-code archives for installation.

## Changelog

### 3.0.4

- Fixed operative resource preloading after Darktide 1.13 renamed the profile package resolver.
- Fixed the transition into Mourningstar loading when Play is pressed during a preconnected session boot.
- Thanks to [Evasion3356](https://github.com/Evasion3356) for the fix in [PR #1](https://github.com/Vansinnet/InstantHub/pull/1).

## License

Licensed under the [MIT License](LICENSE).
