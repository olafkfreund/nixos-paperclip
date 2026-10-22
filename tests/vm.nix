{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "paperclip";

  nodes.machine = {
    imports = [ self.nixosModules.paperclip ];
    services.paperclip.enable = true;
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    machine.wait_for_unit("paperclip.service")
    machine.wait_for_open_port(3100)
    machine.succeed("curl -fsS http://127.0.0.1:3100/api/health")
    machine.succeed("stat -c %a /var/lib/paperclip/auth-secret | grep -x 600")
    machine.fail("journalctl -u paperclip | grep -i 'EROFS\\|read-only file system'")
  '';
}
