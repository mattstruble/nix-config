{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.age
          pkgs.just
          pkgs.sops
        ] ++ lib.optional pkgs.stdenv.isLinux pkgs.nixos-rebuild;
      };
    };
}
