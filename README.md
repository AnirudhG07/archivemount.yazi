# archivemount.yazi

Mounting and unmounting archives in yazi in Linux using `archivemount` command. You can now temporarily view and edit files inside your archive creating a new archive along with original, all using the
features of `archivemount`.

## Previews/Screenshots

[archivemount_p1.webm](https://github.com/user-attachments/assets/f5f8810b-cfbb-4054-b7c2-fa77ed4fc22c)

## Requirements

> [!Note]
>
> Currently Linux only. MacOS usage will be added.

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

## Which Archive files can you use?

Check out the Man page for `archivemount` for more information. `archivemount.yazi` supports `.tar`, `.tar.gz`, `tgz`, `tar.bz2`. If you think more compressions types
can be added, feel free to add it in your `init.lua` and make an issue/PR regarding it as well!:

## TODO
1. Add UI to tell if file is mountpoint or not ( function for it is ready, only UI to configure)
2. Application on MacOS which uses MacFuse for archivemounting.
