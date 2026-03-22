{ ... }:
{
  flake.modules.nixos.ssh =
    { lib, ... }:
    {
      services.openssh = {
        enable = lib.mkDefault true;
        settings = {
          PasswordAuthentication = lib.mkDefault false;
          LoginGraceTime = 0;
          PermitRootLogin = "no";
        };
        hostKeys = [
          {
            path = "/persist/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
          {
            path = "/persist/ssh/ssh_host_rsa_key";
            type = "rsa";
            bits = 4096;
          }
        ];
      };

      programs.ssh = {
        knownHosts = {
          github = {
            hostNames = [
              "github.com"
              "ssh.github.com"
            ];
            publicKey = ''
              ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
            '';
          };

          github-rsa = {
            hostNames = [ "github.com" ];
            publicKey = ''
              ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7
              PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81
              6rMg3x2Cw8f70hZzWrVh4zHmAqzUd2X9r0Wb8OBd9K5K7+R3f5M5k5kN0xgj1wX8u5q3gUuG1
            '';
          };

          github-ecdsa = {
            hostNames = [ "github.com" ];
            publicKey = ''
              ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENj
              8nJ6C9K0uFUxnCLzpSw0DxVh1T/kZLKZVugR5KFHfG3jLx9ZP3Z7nFqOw5sZk9I4V5i2s2J3r8=
            '';
          };
        };
      };
    };
}
