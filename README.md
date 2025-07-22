# nix-config
Configurations for all my NixOS and nix-darwin machines.

# Installation

Assuming NixOS is already installed.
Navigate to the `/etc/nixos/` directory and initialize the repository there:

```bash
nix-shell -p git
git init
git remote add origin https://github.com/mattstruble/nix-config.git
git fetch
git checkout origin/main -b main
```

# References
This repository wouldn't be possible without the help of numerous articles,
YouTube videos, and forum post. Below is a non-exhaustive list of the one's I've
been able to keep track of.

- [notthebee/nix-config](https://github.com/notthebee/nix-config) and the
[related youtube video](https://youtube.com/watch?v=f-x5cB6qCzA)
- [lgug2z handling-secrets-in-nixos-an-overview](https://lgug2z.com/articles/handling-secrets-in-nixos-an-overview/)
- [tsawyer87 sops-nix secrets](https://tsawyer87.github.io/posts/sops-nix/)
- [samleathers](https://samleathers.com/posts/2022-02-11-my-new-network-and-sops.html)
