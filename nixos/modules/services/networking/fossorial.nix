{
  utils,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fossorial;
  cfgFile = pkgs.writeText "config.yml" lib.generators.toYAML { } cfg;
in
{
  options = {
    services.fossorial = {
      enable = lib.mkEnableOption "Fossorial";
      package = lib.mkPackageOption pkgs "fossorial" { };

      baseDomainName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
           Your base fully qualified domain name (without any subdomains)
          '';
        example = "example.com";
      };
      dashboardDomainName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
              The domain where the application will be hosted. This is used for many things, including generating links. You can run Pangolin on a subdomain or root domain.
        '';
        example = "pangolin.example.com";
      };

      letsEncryptEmail = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
              An email address for SSL certificate registration with Lets Encrypt. This should be an email you have access to.
        '';
      };
      tunneling = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
              You can choose not to install Gerbil for tunneling support - in this config it will just be a normal reverse proxy. See how to use without tunneling.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3001;
        description = ''
          Specifies the port to listen on. '';
      };
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/fossorial"; # TODO!!!!!!!!!!!!!!!!!!!!!!!!
        example = "/srv/fossorial";
        description = "Path to variable state data directory for fossorial.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    users.users.fossorial = {
      description = "Fossorial service user";
      group = "fossorial";
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.fossorial = {
    };

    systemd.services.fossorial = {
      description = "Fossorial Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        NODE_OPTIONS = "enable-source-maps";
        NODE_ENV = "development";
        ENVIRONMENT= "prod";
      };
      preStart = ''
        mkdir -p ${cfg.dataDir}/config
        touch ${cfg.dataDir}/config/config.yml
        cp ${cfgFile} ${cfg.dataDir}/config/config.yml
      '';
      serviceConfig = {
        User = "fossorial";
        Group = "fossorial";
        GuessMainPID = true;
        WorkingDirectory = cfg.dataDir;

        BindPaths = [
          "${pkgs.fossorial}/.next:${cfg.dataDir}/.next"
          "${pkgs.fossorial}/public:${cfg.dataDir}/public"
          "${pkgs.fossorial}/dist:${cfg.dataDir}/dist"
          "${pkgs.fossorial}/node_modules:${cfg.dataDir}/node_modules"
        ];

        ExecStartPre = utils.escapeSystemdExecArgs [
          (lib.getExe pkgs.nodejs_22)
          "${pkgs.fossorial}/dist/migrations.mjs"
        ];
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe pkgs.nodejs_22)
          "${pkgs.fossorial}/dist/server.mjs"
        ];
      };
    };
  };
}
