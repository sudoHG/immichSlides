# immichSlides

immichSlides turns your [Immich](https://immich.app) photo library into slideshows on Apple TV, iPad and iPhone.

- SmartFill multi-photo layouts
- Album and people filters
- EXIF information overlay
- PIN protection for settings

immichSlides is unofficial and is not affiliated with Immich or FUTO.

## Get the app

[Download immichSlides on the App Store](https://apps.apple.com/app/apple-store/id6764543664?pt=128838980&ct=github&mt=8).

The full source here is free to build yourself.

## Build it yourself

You need a Mac with Xcode 26.3 and the iOS or tvOS Simulator runtime for your target platform. See [CONTRIBUTING.md](CONTRIBUTING.md#setup) for setup and testing details.

1. Clone or download this repository and open `immichSlides.xcodeproj` in Xcode.
2. In the app target's **Signing & Capabilities**, select your own signing team. To install on a device, also change the bundle identifier (`com.331works.immichSlides`) to one you own; do not commit that local change.
3. Select the `immichSlides` scheme and an iPhone, iPad or Apple TV simulator or device, then run the app.

`Config/env.xcconfig` is optional local test configuration. You do not need it to build or run the app; connect to your Immich server in the app.

With a free Apple ID (Personal Team), device installs expire after 7 days and must be rebuilt and reinstalled. See [Apple's Personal Team limitations](https://developer.apple.com/help/account/basics/about-your-developer-account#enable-a-personal-team-in-xcode).

If you distribute builds of a fork, use a different name and icon as required by [TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests and pull requests, and [AGENTS.md](AGENTS.md) for repository rules.

Contributions are accepted under the terms in [CONTRIBUTING.md](CONTRIBUTING.md#contribution-license).

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

The source code is free software under GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Branding assets are excluded from the GPL; see [TRADEMARKS.md](TRADEMARKS.md).

[Website](https://slides.by331.net/) · [Support](https://slides.by331.net/support/) · [Privacy](https://slides.by331.net/privacy/)
