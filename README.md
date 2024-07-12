# archivemount.yazi

Mounting and unmounting archives in yazi in Linux using `archivemount` command. You can now temporarily view and edit files inside your archive creating a new archive along with original, all using the
features of `archivemount`.

## Previews/Screenshots

TBD

## Requirements

> [!Note]
>
> Currently Linux only. MacOS usage will be added shortly

1. [archivemount](https://github.com/cybernoid/archivemount)

You can download the command using `sudo apt install archivemount` or build from source from their github repository.

2. [Yazi](https://github.com/sxyazi/yazi) version >= 0.2.5

## Installation

To install `archivemount.yazi` in Linux, you can run the below command -

```bash
git clone https://github.com/AnirudhG07/archivemount.yazi ~/.config/yazi/plugins/archivemount.yazi
```

## Usages

Add the following to your `keymaps.toml`.

```toml
[[manager.prepend_keymap]]
on   = [ "m", "a" ]
run  = "plugin archivemount --args=mount"
desc = "Mount selected archive"

[[manager.prepend_keymap]]
on   = [ "m", "u" ]
run  = "plugin archivemount --args=unmount"
desc = "Unmount and save changes to original archive"
```

## TODO

Figure out on using MacFuse for archivemounting.
