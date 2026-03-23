{ inputs, ... }:
{
  perSystem =
    { pkgs, lib, system, ... }:
    {
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.age
          pkgs.just
          pkgs.sops
          inputs.deploy-rs.packages.${system}.default
        ] ++ lib.optional pkgs.stdenv.isLinux pkgs.nixos-rebuild;
      };
    };
}
