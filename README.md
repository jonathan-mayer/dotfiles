# Dotfiles

The dotfiles I use across all my machines.

## Initial Setup

### Setting up Chezmoi

After [installing chezmoi](https://www.chezmoi.io/install) you have to initialize it with this repo:

```bash
chezmoi init git@github.com:jonathan-mayer/dotfiles.git
```

You can then see what changes will be made to your system with:

```bash
chezmoi diff
```

I would recommend backing up your config files if you have non default config in them already:

```bash
cp ~/.bashrc ~/.bashrc.old
# repeat with other files
```

Finally you can apply those changes using:

```bash
chezmoi apply
```
