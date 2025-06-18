# Dotfiles

The dotfiles I use across all my machines.

## Initial Setup

### Setting up Bitwarden Auth

Install [Bitwarden cli](https://bitwarden.com/help/cli).

Log into your account using:

```bash
bw login
```

After entering your E-Mail, Password and OTP you will get a message that will tell you to set a environment variable.
Copy that line, it should look like this:

```bash
export BW_SESSION="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
```

Create the file `~/scripts/setup-bitwarden-auth.bash` and paste the line in there.

### Setting up Chezmoi

After [installing chezmoi](https://www.chezmoi.io/install) you have to initialize it with this repo:

```bash
chezmoi init git@github.com:jonathan-mayer/dotfiles.git
```

You can then see what changes will be made to your system with:

```bash
chezmoi diff
```

I would reccommend backing up your config files if you have non default config in them already:

```bash
cp ~/.bashrc ~/.bashrc.old
# repeat with other files
```

Finally you can apply those changes using:

```bash
chezmoi apply
```
