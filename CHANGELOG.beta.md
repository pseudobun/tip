# Changelog

## [0.1.0-beta.8](https://github.com/pseudobun/tip/compare/v0.1.0-beta.7...v0.1.0-beta.8) (2026-11-14)


### Features

* **settings:** add an app picker to app list fields ([#19](https://github.com/pseudobun/tip/issues/19)) ([ea87128](https://github.com/pseudobun/tip/commit/ea87128a3de8f021ab1f640404efa9effd9c9e51))

## [0.1.0-beta.7](https://github.com/pseudobun/tip/compare/v0.1.0-beta.6...v0.1.0-beta.7) (2026-11-13)


### Features

* **ui:** make liquid glass more see-through and configurable ([#16](https://github.com/pseudobun/tip/issues/16)) ([516c31e](https://github.com/pseudobun/tip/commit/516c31e178aae5670ead952e28d9e7f113e1a874))

## [0.1.0-beta.6](https://github.com/pseudobun/tip/compare/v0.1.0-beta.5...v0.1.0-beta.6) (2026-11-13)


### Bug Fixes

* **config:** apply every config change live and surface config errors ([#13](https://github.com/pseudobun/tip/issues/13)) ([168f64c](https://github.com/pseudobun/tip/commit/168f64c18ca3f5404c4c3fcabce682eb7818b5d0))

## [0.1.0-beta.5](https://github.com/pseudobun/tip/compare/v0.1.0-beta.4...v0.1.0-beta.5) (2026-11-13)


### Bug Fixes

* **bar:** keep the bar at the top of the screen under the menu bar level ([4c822ce](https://github.com/pseudobun/tip/commit/4c822ce3fbe7080354a49591a96688d33180329e))

## [0.1.0-beta.4](https://github.com/pseudobun/tip/compare/v0.1.0-beta.3...v0.1.0-beta.4) (2026-11-13)


### Bug Fixes

* **bar:** let the system menu bar cover tip when it slides down ([48f94de](https://github.com/pseudobun/tip/commit/48f94de152bff9448b209f7ef3e41d202e0e5295))
* **sdk:** run the main run loop so plugin timers fire ([5c12f90](https://github.com/pseudobun/tip/commit/5c12f90067739b89ef5c74d950610bfb9bd479b7))

## [0.1.0-beta.3](https://github.com/pseudobun/tip/compare/v0.1.0-beta.2...v0.1.0-beta.3) (2026-11-13)


### Features

* **ui:** add liquid glass design ([#6](https://github.com/pseudobun/tip/issues/6)) ([5a92c66](https://github.com/pseudobun/tip/commit/5a92c669f0dd91e45960396d1bcbde203cbf962d))

## [0.1.0-beta.2](https://github.com/pseudobun/tip/compare/v0.1.0-beta.1...v0.1.0-beta.2) (2026-11-12)


### Bug Fixes

* **cask:** name the conflicting cask with its tap ([#4](https://github.com/pseudobun/tip/issues/4)) ([f5c1f97](https://github.com/pseudobun/tip/commit/f5c1f978c7fbbb892511f3ac3c4a0ea1f9cf2a59))

## [0.1.0-beta.1](https://github.com/pseudobun/tip/compare/v0.1.0-beta...v0.1.0-beta.1) (2026-11-12)


### Features

* add tip, a native menu bar with islands, themes and plugins ([03a4df6](https://github.com/pseudobun/tip/commit/03a4df680ab32be65b5aad58d61ea48f20cdbff0))
* **animation:** add animation.contentMs for an item's own content changes, 80 ms by default ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **island:** add island.bare so an item floats without a card, the Apple logo by default ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **markets:** use the Nerd Font glyphs for BTC, ETH, gas and NYSE when a Nerd Font is installed ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **network:** split the VPN into its own item and label the link kind ([7215e7b](https://github.com/pseudobun/tip/commit/7215e7b01e62adeb5119ae9762c71f85dff6c915))
* **render:** draw private-use glyphs with an installed Nerd Font ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **workspaces:** glide the visible workspace highlight to its new place ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))


### Performance

* **cpu:** read every process every 10 s and only the busiest 16 in between ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **paw:** draw a workspace focus change at once instead of waiting on a query round trip ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **render:** bound the render cache by 2 MB of bitmaps instead of 512 entries ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
* **render:** draw bitmaps in BGRA and pre-rasterize app icons and symbols at device size ([82f9e55](https://github.com/pseudobun/tip/commit/82f9e553f4b3d5e8cc4b9e026bcf9c846f0e7686))
