# WiZard
WiZard is an open-source macOS menu bar app for [WiZ](https://www.wizconnected.com/) bulbs. It talks to your bulbs over UDP on your local network. No cloud, no account.

<p float="left">

<img width="35%" alt="Menu bar panel" src="https://github.com/user-attachments/assets/d44d1af6-ddd5-4397-abed-8015348ca796" />

<img width="63%" alt="Settings menu" src="https://github.com/user-attachments/assets/903b4091-fc45-4ac6-9ecc-fa9bb171ba5a" />

</p>




## Features
- Presets in your menu bar: Cool, Warm, Nightlight, plus any preset you create
- White temperature (2200 to 6500 K), RGB colors, and all 36 built-in WiZ scenes
- Bulb discovery, renaming, and switching between multiple bulbs

## Install
Make sure you have Xcode Command Line Tools (`xcode-select --install`).

```console
git clone https://github.com/arshzip/wizard
cd wizard
./build.sh
```

The script compiles the app, signs it, and installs it to `/Applications`. Launch WiZard and it finds your bulb on the network.

> [!NOTE]
> macOS may refuse to open WiZard since it isn't notarized. Bypass Gatekeeper with:
>
> ```console
> xattr -d com.apple.quarantine /Applications/WiZard.app
> ```

## How it works
WiZ bulbs listen for JSON on UDP port 38899. WiZard sends `getPilot` to read the state and `setPilot` to change it. Discovery sends a broadcast first, then sweeps the subnet if the broadcast gets dropped.

Settings live in `~/.wizctl.json`. 

## License
[MIT](LICENSE)
