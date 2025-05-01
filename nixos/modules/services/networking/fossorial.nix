{
  utils,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fossorial;
  cfgTxt = lib.generators.toYAML { } settings;
  cfgFile = pkgs.writeText "config.yml" cfgTxt;
  settings = {
    app = {
      dashboard_url = "https://${cfg.baseDomain}";
      log_level = "info";
      save_logs = false;
    };
    domains = {
      domain1 = {
        base_domain = cfg.baseDomain;
        cert_resolver = "letsencrypt";
        prefer_wildcard_cert = false;
      };
    };
    server = {
      external_port = cfg.externalPort;
      internal_port = cfg.internalPort;
      next_port = cfg.nextPort;
      internal_hostname = "pangolin";
      session_cookie_name = "p_session_token";
      resource_access_token_param = "p_token";
      resource_access_token_headers = {
        id = "P-Access-Token-Id";
        token = "P-Access-Token";
      };
      resource_session_request_param = "p_session_request";
    };
    traefik = {
      cert_resolver = "letsencrypt";
      http_entrypoint = "web";
      https_entrypoint = "websecure";
    };
    gerbil = {
     start_port = 51820;
     base_endpoint = cfg.baseDomain;
     block_size = 24;
     site_block_size = 30;
     subnet_group = "100.89.137.0/20";
     use_subdomain = true;
    };
    rate_limits = {
      global = {
         window_minutes = 1;
         max_requests = 500;
      };
    };
    users = {
      server_admin = {
        email = "admin@example.com";
        password = "Password123!";
      };
    };
    flags = {
      require_email_verification = false;
      disable_signup_without_invite = true;
      disable_user_create_org = true;
      allow_raw_resources = true;
      allow_base_domain_resources = true;
      };
  };
in
{
  options = {
    services.fossorial = {
      enable = lib.mkEnableOption "Fossorial";
      package = lib.mkPackageOption pkgs "fossorial" { };

      baseDomain = lib.mkOption {
        type = lib.types.str;
        default = "example.com";
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
      externalPort = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = ''
          Specifies the port to listen on for the external server '';
      };
      internalPort = lib.mkOption {
        type = lib.types.port;
        default = 3001;
        description = ''
          Specifies the port to listen on for the internal server '';
      };
      nextPort = lib.mkOption {
        type = lib.types.port;
        default = 3002;
        description = ''
          Specifies the port to listen on for the nextjs frontend '';
      };
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/fossorial";
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
        Restart = "always";

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
