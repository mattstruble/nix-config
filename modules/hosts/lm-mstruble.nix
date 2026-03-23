{ inputs, ... }:
{
  flake.modules.darwin.lm-mstruble = {
    imports = with inputs.self.modules.darwin; [
      tier-workstation
    ];

    networking.hostName = "lm-mstruble";
    system.stateVersion = 4;

    # Host-specific overrides loaded from private submodule
    # TODO: wire in hosts-private/lm-mstruble/ submodule when ready
  };
}
