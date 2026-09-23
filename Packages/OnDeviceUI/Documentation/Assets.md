# Assets and references

## Runtime resources

- `Sources/OnDeviceUI/Resources/DesignAssets.xcassets` contains semantic light/dark colors. They are bundled by Swift Package Manager and resolved through `Bundle.module`.
- Interface icons use SF Symbols and text uses system fonts. No generated button, tab-bar, glass texture or font bitmap is needed.
- `Example/OnDeviceUIDemo/Resources/studio-example.png` is a generated illustration for the example’s **Show image result** control. It is a bundled fixture, not output produced by a running on-device model. The example must keep its sample-data label.
- The `notes.txt` attached-draft preview is metadata only. No corresponding user file is read, uploaded, parsed or sent.

## Design references

[composer-content-concept.png](Reference/composer-content-concept.png) is a generated reference for chat/composer content. It is not an iOS simulator screenshot, a measured view hierarchy or proof of native Liquid Glass behavior. The concept omits native bars. SwiftUI supplies native navigation, keyboard behavior, button highlights and selection rendering.

[composer-layout.svg](Reference/composer-layout.svg) accompanies [LayoutMetrics.md](LayoutMetrics.md). It illustrates app-owned equations and minimum-target examples, not measured Apple control dimensions. The operating system owns the real navigation, tab-bar, keyboard and button geometry.

Both files live in `Documentation/Reference`. They are review material, not production UI backgrounds.

## Research

The primary composer reference is the retained official **Codex desktop demo** associated with the [official desktop app documentation](https://learn.chatgpt.com/docs/app). Its writing area above a footer is observable in the poster and 12-second frame; no build date is exposed. Treat it as reference material rather than proof of the exact current desktop build.

We also reviewed the [Apple Messages guide](https://support.apple.com/guide/iphone/send-and-reply-to-messages-iph82fb73ba3/ios), [official ChatGPT App Store listing](https://apps.apple.com/us/app/chatgpt/id6448311069), [official Claude App Store listing](https://apps.apple.com/us/app/claude-by-anthropic/id6473753684) and [Hermes’s design contract](https://github.com/NousResearch/hermes-agent/blob/main/apps/desktop/DESIGN.md).

These secondary references informed transcript readability, attachment visibility and control clarity. Our composer places writing and footer controls inside one surface, adapts them to touch, and retains only OnDevice’s existing actions. The delivered app remains OnDevice; these references do not transfer other products’ features, branding or implementation. App Store screenshots are promotional reference images rather than a live inspection of a currently installed app.
