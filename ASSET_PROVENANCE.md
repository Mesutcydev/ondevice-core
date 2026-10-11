# Asset provenance

## Repository artwork

The app icons, interface illustrations, screenshots, and repository
specification chart tracked outside third-party directories are represented as
original project assets unless a nearby notice says otherwise. They are
licensed under the repository MIT license as software/documentation assets.

Contributors adding or replacing an asset must record:

- creator or upstream project;
- source URL or creation method;
- copyright holder;
- license and redistribution conditions; and
- whether people, trademarks, or private information appear.

## Generated promotional artwork

`Docs/Images/ios-local-llm-spec-chart.svg` is an original diagram assembled
from repository facts. The PNG is a raster rendering of that SVG. Neither file
contains model weights, screenshots of private data, or third-party logos.

## OnDevice Max portfolio motion — October 10, 2026

`PortfolioAssets/OnDeviceMax-Motion/` contains original promotional motion
created with AI assistance for the project owner, following the black, white,
red, and dotted typography direction of `https://ondevice.fun/`. Original code,
composition, device frames, animation, posters, and video exports are copyright
2026 Mesut and iOS Local LLM contributors and use this repository's MIT license.

The graphic reuses the repository's App Store QA captures for Chat, Sidebar,
Voice, and Models (`AppStoreScreenshots/1.0-81/en-US/iphone-6.9/`) and the current
angular waveform `AppIcon-1024.png`. Source paths and SHA-256 hashes are recorded
in the asset directory's manifest. Screens contain synthetic fixture content;
no people, user documents, credentials, model weights, stock art, music, or font
files were added. Native iPhone chrome and symbols are interface context, not
Apple endorsement. The video is promotional artwork, not runtime performance
evidence. Fonts are rendered from local system fonts and are not redistributed.

The browser version contains original Canvas/JavaScript with no runtime
dependencies. Native export tools (`@napi-rs/canvas` 0.1.100, sharp, and FFmpeg)
are not included in the deliverable. See its README for recreation and embedding.

## Simulator screenshots

`Docs/Images/Screenshots/*.png` were captured on 29 July 2026 from an
iPhone 17 simulator running the repository's Debug source build. They are
unedited app UI captures created by the maintainer during repository
validation. The clean app state contains no user content, account identifiers,
tokens, local-network addresses, notifications, or downloaded model weights.
Apple's simulated iPhone chrome and SF Symbols appear only as necessary
interface context; Apple does not sponsor or endorse this project.

## Excluded assets

AI model weights, compiled Core ML models, generated XCFrameworks, installers,
archives, and signing assets are excluded from Git. Screenshots submitted to
issues or pull requests must use synthetic data and remove notifications,
account identifiers, device names, tokens, and local-network addresses.
