{
  utils,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.newt;
in
{
  options = {
    services.newt = {
      enable = lib.mkEnableOption "Newt";
      # provide path to file to keep secrets out of the nix store
      configFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing the following json
          {
            "id": "<id>",
            "secret": "<secret>",
            "endpoint": "<dashboardDomain>"
          }
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configFile != null;
        message = "services.newt.configFile must be provided when newt is enabled";
      }
    ];

    users.users.newt = {
      isSystemUser = true;
      group = "newt";
      home = "/var/lib/newt";
    };
    users.groups.newt = {};

    systemd.services.newt = {
      description = "Newt Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        User = "newt";
        Group = "newt";
        StateDirectory = "newt";
        WorkingDirectory = "%S/newt";
        Restart = "always";
        RestartSec = "10s";
        ExecStart =
        let
          newtConfig = builtins.fromJSON (builtins.readFile cfg.configFile);
        in
        utils.escapeSystemdExecArgs (
          [
            (lib.getExe' pkgs.fosrl-newt "newt")
            "--id" newtConfig.id
            "--secret" newtConfig.secret
            "--endpoint" newtConfig.endpoint
          ]
        );
      };
    };
  };
}
