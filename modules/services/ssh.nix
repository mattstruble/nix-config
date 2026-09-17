{ ... }:
{
  flake.modules.nixos.ssh =
    { lib, ... }:
    {
      services.openssh = {
        enable = lib.mkDefault true;
        settings = {
          PasswordAuthentication = false;
          LoginGraceTime = 60;
          PermitRootLogin = "no";
        };
      };

      programs.ssh = {
        knownHosts = {
          github = {
            hostNames = [
              "github.com"
              "ssh.github.com"
            ];
            publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
          };

          github-rsa = {
            hostNames = [ "github.com" ];
            publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
          };

          github-ecdsa = {
            hostNames = [ "github.com" ];
            publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
          };
        };
      };
    };

  flake.modules.homeManager.ssh-client =
    { config, ... }:
    let
      onePassPath = "~/Library/Group\\ Containers/2BUA8C4S2C.com.1password/t/agent.sock";
    in
    {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;

        matchBlocks = {
          "*" = {
            compression = true;
            addKeysToAgent = "yes";
            controlMaster = "auto";
            controlPath = "/tmp/ssh-%u-%r@%h:%p";
            controlPersist = "no";
            forwardAgent = true;
            serverAliveInterval = 60;
            hashKnownHosts = true;
            userKnownHostsFile = "${config.home.homeDirectory}/.ssh/known_hosts";
            identityAgent = "${onePassPath}";
          };
        };
      };
    };
}
