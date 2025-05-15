{
  utils,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fossorial;
  cfgTxt = lib.generators.toYAML { } pangolinConf;
  cfgFile = pkgs.writeText "config.yml" cfgTxt;
  pangolinConf = {
    app = {
      dashboard_url = "https://${cfg.dashboardDomain}";
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
     subnet_group = "100.89.128.1/24";
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
        email = cfg.letsEncryptEmail;
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

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to open the ports in the firewall for the fossorial service(s)
        '';
      };

      baseDomain = lib.mkOption {
        type = lib.types.str;
        default = "example.com";
        description = ''
           Your base fully qualified domain name (without any subdomains)
        '';
        example = "example.com";
      };
      dashboardDomain = lib.mkOption {
        type = lib.types.str;
        default = "pangolin.example.com";
        description = ''
          The domain where the application will be hosted. This is used for many things, including generating links. You can run Pangolin on a subdomain or root domain. Do not prefix with http or https
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
      externalPort = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = ''
          Specifies the port to listen on for the external server.
        '';
      };
      internalPort = lib.mkOption {
        type = lib.types.port;
        default = 3001;
        description = ''
          Specifies the port to listen on for the internal server.
        '';
      };
      nextPort = lib.mkOption {
        type = lib.types.port;
        default = 3002;
        description = ''
          Specifies the port to listen on for the nextjs frontend.
        '';
      };
      gerbilPort = lib.mkOption {
        type = lib.types.port;
        default = 3003;
        description = ''
          Specifies the port to listen on for gerbil.
        '';
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

    networking.firewall = lib.mkIf cfg.openFirewall {
       allowedTCPPorts = [ 80 443 ];
       allowedUDPPorts = [ 51820 ];
     };

    users.users.fossorial = {
      description = "Fossorial service user";
      group = "fossorial";
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.fossorial = {
      members = [ "fossorial" "traefik"];
    };
    # order is as follows
    # "systemd-tmpfiles-resetup.service"
    # "fossorial.service"
    # "gerbil.service"
    # "traefik.service"
    systemd.services = {
      fossorial = {
        description = "Fossorial Service";
        wantedBy = [ "multi-user.target" ];
        requires = [ "network.target" "systemd-tmpfiles-resetup.service"];
        after = [ "network.target" "systemd-tmpfiles-resetup.service"];
        environment = {
          NODE_OPTIONS = "enable-source-maps";
          NODE_ENV = "development";
          ENVIRONMENT = "prod";
        };
        preStart = ''
          mkdir -p ${cfg.dataDir}/config
          touch ${cfg.dataDir}/config/config.yml
          cp ${cfgFile} ${cfg.dataDir}/config/config.yml
        '';
        serviceConfig = {
          User = "fossorial";
          Group = "fossorial";
          WorkingDirectory = cfg.dataDir;
          Restart = "always";
          GuessMainPID = true;
          # allow fossorial group members to write to folder
          UMask = "022";

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
      gerbil = {
        description = "Gerbil Service";
        wantedBy = [ "multi-user.target" ];
        after = [ "fossorial.service" ];
        requires = [ "fossorial.service" ];
        before = [ "traefik.service" ];
        requiredBy  = [ "traefik.service" ];

        # TODO: add the rest of the envvars
        environment = {
          LISTEN = "localhost:" + builtins.toString cfg.gerbilPort;
        };

        serviceConfig = {
          User = "fossorial";
          Group = "fossorial";
          WorkingDirectory = cfg.dataDir;
          Restart = "always";
          AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_SYS_MODULE"];
          CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_SYS_MODULE"];

          ExecStart = utils.escapeSystemdExecArgs [
            ("${pkgs.fossorial-gerbil}/bin/gerbil")
            "--reachableAt=http://gerbil:${builtins.toString cfg.gerbilPort}"
            "--generateAndSaveKeyTo=${builtins.toString cfg.dataDir}/config/key"
            "--remoteConfig=http://localhost:${builtins.toString cfg.internalPort}/api/v1/gerbil/get-config"
            "--reportBandwidthTo=http://localhost:${builtins.toString cfg.internalPort}/api/v1/gerbil/receive-bandwidth"
          ];
        };
      };
      # make sure traefik places plugins in local dir instead of /
      traefik.serviceConfig.WorkingDirectory = "${cfg.dataDir}/config/traefik";
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0755 fossorial fossorial - - "
      "d '${cfg.dataDir}/config' 0755 fossorial fossorial - -"
      "d '${cfg.dataDir}/config/letsencrypt' 0755 traefik traefik - - "
    ];

    services.traefik = {
      enable = true;
      group = "fossorial";
      dataDir = "${cfg.dataDir}/config/traefik";
      staticConfigOptions = {
        api = {
          insecure = true;
          dashboard = true;
        };
        providers = {
          http = {
            endpoint = "http://localhost:${builtins.toString cfg.internalPort}/api/v1/traefik-config";
            pollInterval = "5s";
          };
          file.filename = "/etc/traefik/dynamic_config.yml";
        };
        experimental.plugins.badger = {
          moduleName = "github.com/fosrl/badger";
          version = "v1.1.0";
        };
        log = {
          level = "INFO";
          format = "common";
        };
        certificatesResolvers = {
          letsencrypt = {
            acme = {
              httpChallenge.entryPoint = "web";
              email = cfg.letsEncryptEmail; # REPLACE THIS WITH YOUR EMAIL
              storage = "${cfg.dataDir}/config/letsencrypt/acme.json";
              caServer = "https://acme-v02.api.letsencrypt.org/directory";
            };
          };
        };
        entryPoints = {
          web.address = ":80";
          websecure = {
            address = ":443";
            transport.respondingTimeouts.readTimeout = "30m";
            http.tls.certResolver = "letsencrypt";
          };
        };
        serversTransport.insecureSkipVerify = true;
      };
      dynamicConfigOptions = {
        http = {
          middlewares.redirect-to-https.redirectScheme.scheme = "https";
          routers = {
            # HTTP to HTTPS redirect router
            main-app-router-redirect = {
              rule = "Host(`${cfg.dashboardDomain}`)"; # REPLACE THIS WITH YOUR DOMAIN
              service = "next-service";
              entryPoints = [ "web" ];
              middlewares = [ "redirect-to-https" ];
            };
            # Next.js router (handles everything except API and WebSocket paths)
            next-router = {
              rule = "Host(`${cfg.dashboardDomain}`) && !PathPrefix(`/api/v1`)"; # REPLACE THIS WITH YOUR DOMAIN
              service = "next-service";
              entryPoints = [ "websecure" ];
              tls.certResolver = "letsencrypt";
            };
            # API router (handles /api/v1 paths)
            api-router = {
              rule = "Host(`${cfg.dashboardDomain}`) && PathPrefix(`/api/v1`)"; # REPLACE THIS WITH YOUR DOMAIN
              service = "api-service";
              entryPoints = [ "websecure" ];
              tls.certResolver = "letsencrypt";
            };
            # WebSocket router
            ws-router = {
              rule = "Host(`${cfg.dashboardDomain}`)"; # REPLACE THIS WITH YOUR DOMAIN
              service = "api-service";
              entryPoints = [ "websecure" ];
              tls.certResolver = "letsencrypt";
            };
          };
          services = {
            next-service.loadBalancer.servers = [ { url = "http://localhost:${builtins.toString cfg.nextPort}"; } ]; # Next.js server
            api-service.loadBalancer.servers = [ { url = "http://localhost:${builtins.toString cfg.externalPort}"; } ]; # API/WebSocket server
          };
        };
      };
    };
  };
}
