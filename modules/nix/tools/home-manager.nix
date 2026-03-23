{ inputs, ... }:
{
  flake.modules.nixos.home-manager-integration = {
    imports = [ inputs.home-manager.nixosModules.home-manager ];

    home-manager = {
      useGlobalPkgs = true;
      backupFileExtension = "bak";
    };
  };

  flake.modules.darwin.home-manager-integration =
    {
      imports = [ inputs.home-manager.darwinModules.home-manager ];

      home-manager = {
        useGlobalPkgs = true;
        backupFileExtension = "backup";
      };

      # Copy .app bundles instead of symlinking (Spotlight/Launchpad compatibility)
      home-manager.sharedModules = [
        ({ config, pkgs, lib, ... }: {
          home.file."Applications/Home Manager Apps".enable = false;
          home.activation.copyApps =
            let
              apps = pkgs.buildEnv {
                name = "home-manager-applications";
                paths = config.home.packages;
                pathsToLink = [ "/Applications" ];
              };
              v = "\${VERBOSE_ARG:+-v}";
            in
            lib.hm.dag.entryAfter [ "linkGeneration" ] ''
              baseDir="$HOME/Applications/Home Manager Apps"
              $DRY_RUN_CMD mkdir -p "$baseDir"
              shopt -s nullglob
              for app in "$baseDir"/*; do
                if [ ! -e "${apps}/Applications/$(basename "$app")" ]; then
                  $DRY_RUN_CMD rm -r ${v} "$app"
                fi
              done
              for app in ${apps}/Applications/*; do
                source="$(readlink "$app")"
                target="$baseDir/$(basename "$app")"
                temp="$(mktemp -u "$target.XXXXXX")"
                $DRY_RUN_CMD cp ${v} -HLR "$source" "$temp"
                $DRY_RUN_CMD chmod ${v} -R +w "$temp"
                if [ -e "$target" ]; then
                  $DRY_RUN_CMD rm -r ${v} "$target"
                fi
                $DRY_RUN_CMD mv ${v} "$temp" "$target"
              done
            '';
        })
      ];
    };
}
