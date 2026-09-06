# Omarchy Input Method

Bar widget for [Omarchy](https://omarchy.org/) that shows the active [fcitx5](https://fcitx-im.org/) input method and switches it from a panel.

Labels: **中** Rime, **あ** Mozc, **EN** US keyboard / Rime ascii mode.

![Omarchy Input Method](preview.png)

## Install

```sh
omarchy plugin add https://github.com/kazedayo/omarchy-input-method.git --enable
```

Place it:

```sh
omarchy bar move io.github.kaz.omarchy-input-method --section right
```

## Usage

- Left click: open the picker (input methods, Rime schema, ascii mode, Mozc settings)
- Right click: `fcitx5-remote -t`
- Escape: close the panel

## Dependencies

Does not install these. You need them on the host:

- Omarchy Quattro (`omarchy-shell`)
- `fcitx5` and `fcitx5-remote`
- `busctl` (systemd)
- [fcitx5-rime](https://github.com/fcitx/fcitx5-rime) for 中 / schema / ascii mode
- Mozc (`/usr/lib/mozc/mozc_tool`) for あ
- font `Noto Sans CJK JP`

Other fcitx5 IMs still appear in the picker; only Rime and Mozc get extra actions.

## Remove

```sh
omarchy plugin remove io.github.kaz.omarchy-input-method
```

Does not change fcitx5 config.

## License

MIT. See [LICENSE](LICENSE).
