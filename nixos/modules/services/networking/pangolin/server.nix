{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib.cli) toGNUCommandLineShell;
  inherit (lib)
    all
    allUnique
    any
    assertOneOf
    attrNames
    attrValues
    concatMapStringsSep
    concatStringsSep
    const
    elem
    elemAt
    filterAttrsRecursive
    findFirstIndex
    genAttrs
    getExe
    hasPrefix
    head
    imap0
    intersectLists
    isAttrs
    last
    listToAttrs
    literalExpression
    maintainers
    mapAttrs'
    mapAttrsToList
    mapCartesianProduct
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    mutuallyExclusive
    nameValuePair
    optional
    optionalAttrs
    optionalString
    optionals
    removePrefix
    removeSuffix
    splitString
    subtractLists
    tail
    toUpper
    unique
    zipAttrs
    ;

  inherit (config.security) acme;
  inherit (config.services)
    badger
    gerbil
    pangolin
    traefik
    ;
  format = pkgs.formats.yaml { };

  dashboardDomain = removePrefix "https://" pangolin.settings.app.dashboard_url;
  baseDomainForDashboard = concatStringsSep "." (tail (splitString "." dashboardDomain));

  baseDomainMatchingDashboardIndexList = map (domain: domain.base_domain == baseDomainForDashboard) (
    attrValues pangolin.settings.domains
  );

  dashboardDomainAttrName = elemAt (findFirstIndex (bool: bool == true) (throw ''
    This error has occured because 'findFirstIndex' could not find
    a matching domain index in 'baseDomainMatchingDashboardIndexList'.
    This should never happen, as the NixOS assertion system would've
    prevented you from evaluating an invalid configuration in
    'services.pangolin.settings.domains'. Please report this as a
    bug against Nixpkgs.
  '') baseDomainMatchingDashboardIndexList) (attrNames pangolin.settings.domains);
in
{
  options.services =
    let
      inherit (lib.types)
        attrsOf
        bool
        float
        int
        listOf
        nullOr
        oneOf
        path
        port
        str
        submodule
        ;
    in
    {
      pangolin = {
        enable = mkEnableOption "Pangolin, an identity-aware gateway to private applications";
        package = mkPackageOption pkgs "fosrl-pangolin" { };
        openFirewall = mkEnableOption "" // {
          # No point in using Pangolin with these ports blocked.
          default = true;
          description = ''
            Whether to open TCP ports 80 and 443 in the firewall for the
            Pangolin dashboard.

            If you set up any raw resources on the Pangolin dashboard, please add
            their ports to 'services.pangolin.extraPorts', and those ports will be
            allowlisted from the firewall as well.
          '';
        };

        extraPorts =
          let
            mkPortOption =
              type:
              assert assertOneOf "type" type [
                "tcp"
                "udp"
              ];
              mkOption {
                type = listOf port;
                default = [ ];
                example = [ 22 ];
                description = ''
                  Pangolin can proxy raw ${toUpper type} resources by exposing them to
                  a given port. When setting up a new raw resource, Pangolin will
                  provide some Traefik configuration options to expose the resource on
                  the remote server's ports.

                  Simply add the port numbers here and the Pangolin module will handle
                  the firewall and Traefik configuration.
                '';
              };
          in
          genAttrs [ "tcp" "udp" ] (type: mkPortOption type);

        settings =
          let
            freeformType = format.type // {
              description = "YAML value, plus NixOS-specific options prefixed with an underscore";
            };
          in
          mkOption {
            defaultText = literalExpression ''
              {
                # This needs to be manually set to a string by the user.
                app.dashboard_url = null;

                # A domain named 'default' is always created, unless
                # 'services.pangolin.settings._createDefaultDomain' is set to 'false'.
                domains.default = {
                  # If 'app.dashboard_url' is 'https://pangolin.example.com', this
                  # function will set the base_domain to 'example.com'.
                  base_domain = concatStringsSep "." (
                    tail (splitString "." (removePrefix "https://" config.services.pangolin.settings.app.dashboard_url))
                  );
                  prefer_wildcard_cert = false;
                };

                server = {
                  external_port = 3000;
                  internal_port = 3001;
                  next_port = 3002;
                  integration_port = 3003;

                  # The 'internal_hostname' is resolved by the machine running
                  # Badger and needs to resolve to a machine running this Pangolin
                  # configuration. If you have a split Gerbil/Pangolin setup, then
                  # this should be the address of your Pangolin installation, as
                  # Badger is running in the machine running Gerbil.
                  internal_hostname = "localhost";
                };

                # This can be set to a completely different URL, if Gerbil is
                # running on a separate VPS. Setting this option to a different URL
                # will automatically disable 'services.gerbil.enable' on the machine
                # running Pangolin.
                gerbil.base_endpoint = removePrefix "https://" config.services.pangolin.settings.app.dashboard_url;
              }
            '';
            description = ''
              The Pangolin server configuration. See the [Pangolin Documentation](https://docs.digpangolin.com/self-host/advanced/config-file)
              for the available options. Values added here are converted to YAML and
              written to the `config.yml` file Pangolin uses to set itself up.
            '';
            example = {
              _dontCreateDefaultDomain = true;
              app.dashboard_url = "https://pangolin.example.com";
              server.internal_port = 3008;
              domains.default.prefer_wildcard_cert = true;
              gerbil.base_endpoint = "some-other.server.com";
            };
            type = submodule {
              inherit freeformType;
              options =
                let
                  domainOptions =
                    isTraefik: config:
                    let
                      domainType = if isTraefik then "UI-provisioned domains" else "this domain";
                    in
                    {
                      _dnsProvider = mkOption {
                        type = str;
                        description = ''
                          The DNS provider for ${domainType}, for setting up the
                          DNS-01 challenge. This option does not need to be set if
                          `prefer_wildcard_cert` is not set to `true`.

                          This setting must be set to one of the supported Provider
                          Codes listed in the [Traefik Documentation](https://doc.traefik.io/traefik/https/acme/#providers),
                          and the API keys for your provider must be added to an
                          environment file in `services.traefik.environmentFiles`.
                        '';
                        default = config.cert_resolver;
                      };
                      cert_resolver = mkOption {
                        type = str;
                        description = ''
                          The certificate resolver to use for ${domainType}.

                          This is the name passed to Traefik for the static configuration
                          resolver, which may differ from the actual DNS provider for
                          ${domainType}. To configure a different provider code, use the
                          `_dnsProvider` option.
                        '';
                        default = "letsencrypt";
                      };
                      prefer_wildcard_cert = mkEnableOption "wildcard certificate generation and the DNS-01 challenge for ${domainType}";
                    };
                in
                {
                  _dontCreateDefaultDomain = mkEnableOption "" // {
                    description = "Whether to skip creating the default domain for Pangolin.";
                  };
                  app.dashboard_url = mkOption {
                    type = nullOr str;
                    description = "The URL for the Pangolin dashboard.";
                    default = null;
                  };
                  domains = mkOption {
                    type = attrsOf (
                      submodule (
                        { config, ... }:
                        {
                          inherit freeformType;
                          options = (domainOptions false config) // {
                            base_domain = mkOption {
                              type = nullOr str;
                              description = ''
                                The address configured by this domain. It must be defined
                                if this attribute is accessed.
                              '';
                              default = null;
                              example = "example.com";
                            };
                          };
                        }
                      )
                    );
                    description = "The domains to be configured by Pangolin.";
                    default =
                      if pangolin.settings._dontCreateDefaultDomain then
                        { }
                      else
                        {
                          default.base_domain = concatStringsSep "." (tail (splitString "." dashboardDomain));
                        };
                    defaultText = ''
                      if config.services.pangolin.settings._dontCreateDefaultDomain then
                        { }
                      else
                        {
                          default.base_domain = concatStringsSep "." (
                            tail (splitString "." (removePrefix "https://" config.services.pangolin.settings.app.dashboard_url))
                          );
                        }
                    '';
                  };
                  traefik = mkOption {
                    type = attrsOf (
                      submodule (
                        { config, ... }:
                        {
                          inherit freeformType;
                          options =
                            (domainOptions true config)
                            // (genAttrs
                              [
                                "http_entrypoint"
                                "https_entrypoint"
                              ]
                              (
                                name:
                                let
                                  type = removePrefix "_entrypoint" name;
                                in
                                mkOption {
                                  type = str;
                                  description = ''
                                    The ${toUpper type} entryPoint name for ${toUpper type} traffic.
                                  '';
                                  default = if type == "http" then "web" else "websecure";
                                }
                              )
                            );
                        }
                      )
                    );
                    description = "The Traefik configuration for Pangolin.";
                  };
                  server =
                    listToAttrs (
                      imap0
                        (
                          index: name:
                          nameValuePair name (mkOption {
                            type = port;
                            default = 3000 + index;
                            description = "The ${toString (splitString "_" name)} for Pangolin.";
                            # This module is big and complicated.
                            # Let's take a break by having fun with port numbers.
                            example = 2000 + ((420 * (index + 5)) - (32 * (index + 1)));
                          })
                        )
                        [
                          "external_port"
                          "internal_port"
                          "next_port"
                          "integration_port"
                        ]
                    )
                    // {
                      internal_hostname = mkOption {
                        type = str;
                        description = ''
                          The internal hostname for this Pangolin installation,
                          used by Badger to connect to the Pangolin API.
                        '';
                        default = "localhost";
                        example = "pangolin.example.com";
                      };
                    };
                  gerbil.base_endpoint = mkOption {
                    type = str;
                    default = dashboardDomain;
                    defaultText = "removePrefix \"https://\" config.services.pangolin.settings.app.dashboard_url";
                    example = "gerbil.example.com";
                    description = ''
                      The address where Gerbil can be found. If Gerbil is running
                      on this machine, then it's the same as the value of
                      `services.pangolin.settings.app.dashboard_url`, minus the
                      protocol. If Gerbil is running on another machine, then
                      this should point to the public address of that machine.
                    '';
                  };
                };
            };
          };

        # provide path to file to keep secrets out of the nix store
        environmentFile = mkOption {
          type = nullOr path;
          default = null;
          description = ''
            Path to a file containing sensitive environment variables for Pangolin.
            See the [Pangolin Documentation](https://docs.digpangolin.com/self-host/advanced/config-file#environment-variables)
            for more information.

            These will overwrite anything defined in the config. The file should
            contain environment variable assignments similar to the following:

            ```
            SERVER_SECRET=1234567890abc
            ```
          '';
          example = "/etc/nixos/secrets/pangolin.env";
        };
      };

      gerbil = {
        enable = mkEnableOption "Gerbil, tunnel manager for Pangolin" // {
          default = pangolin.enable && dashboardDomain == pangolin.settings.gerbil.base_endpoint;
          defaultText = literalExpression ''
            config.services.pangolin.enable && (removePrefix "https://" config.services.pangolin.settings.app.dashboard_url) == config.services.pangolin.settings.gerbil.base_endpoint
          '';
        };
        package = mkPackageOption pkgs "fosrl-gerbil" { };
        openFirewall = mkEnableOption "" // {
          # No point in using Gerbil with these ports blocked.
          default = true;
          description = ''
            Whether to open UDP ports 21820 and 51820 in the firewall for the
            Gerbil WireGuard connection(s).

            On a split Pangolin/Gerbil setup, this will also expose the port
            configured in `services.gerbil.port`, as well as ports 80 and 443
            for Traefik, and any ports configured in `services.pangolin.extraPorts`.
          '';
        };
        port = mkOption {
          type = port;
          default = 3004;
          description = ''
            Specifies the port to listen on for Gerbil.
          '';
        };

        settings = mkOption {
          defaultText = literalExpression ''
            {
              # This address needs to be reachable by Pangolin. If Gerbil is
              # running on a different machine than Pangolin, it should be set
              # to a publicly accessible address.
              reachableAt = null;

              # One of the two options below needs to be set by the user. The
              # 'remoteConfig' attribute should be set to the appropriate Pangolin
              # API path, or 'config' should be set to a path to a JSON file
              # containing the Gerbil configuration.
              remoteConfig = null;
              config = null;

              generateAndSaveKeyTo = "gerbil-key";
              listen = "localhost:''${toString config.services.gerbil.port}";
            }
          '';
          example = {
            reachableAt = "http://198.51.100.1:3000";
            remoteConfig = "https://pangolin.example.test/api/v1/gerbil/get-config";
          };
          description = ''
            The command line options passed to Gerbil.

            If `services.pangolin.enable` is set to `true`, then no additional
            configuration is necessary.
          '';
          type = submodule {
            freeformType =
              let
                valueType =
                  nullOr (oneOf [
                    bool
                    int
                    float
                    str
                    path
                    (listOf valueType)
                  ])
                  // {
                    description = "value coercible to CLI argument";
                  };
              in
              valueType;
            options = {
              reachableAt = mkOption {
                type = nullOr str;
                description = ''
                  How Gerbil should announce its HTTP server to Pangolin. This
                  should be a publicly accessible address if Pangolin is not
                  running on the same machine, or just `localhost:''${config.services.gerbil.port}`
                  if Pangolin can access Gerbil via `localhost`.
                '';
                default = if pangolin.enable then "http://${toString gerbil.settings.listen}" else null;
                defaultText = literalExpression ''
                  if config.services.pangolin.enable then
                    "http://''${toString config.services.gerbil.settings.listen}"
                  else
                    null
                '';
              };
              generateAndSaveKeyTo = mkOption {
                type = str;
                description = ''
                  Relative or absolute path passed to Gerbil in order to generate
                  the WireGuard private key. This file is managed by Gerbil, and it
                  is not necessary to deploy it in Nix using a secrets management solution.

                  Please note that `gerbil.service` runs as a dynamic user. If this
                  option is configured to an absolute path, it may be necessary to
                  change some settings in `systems.services.gerbil.serviceConfig`
                  in order to mitigate the lack of permissions of the dynamic user.
                '';
                default = "gerbil-key";
              };
              remoteConfig = mkOption {
                type = nullOr str;
                description = ''
                  The address to `gerbil/get-config` in the Pangolin API, if `services.gerbil.settings.config` is undefined.
                '';
                default =
                  if pangolin.enable then
                    "http://localhost:${toString pangolin.settings.server.internal_port}/api/v1/gerbil/get-config"
                  else
                    null;
                defaultText = literalExpression ''
                  if config.services.pangolin.enable then
                    "http://localhost:''${toString config.services.pangolin.settings.server.internal_port}/api/v1/gerbil/get-config"
                  else
                    null
                '';
              };
              config = mkOption {
                type = nullOr str;
                description = ''
                  The path to the Gerbil configuration file, if `services.gerbil.settings.remoteConfig` is undefined.
                '';
                default = null;
              };
              listen = mkOption {
                type = str;
                description = ''
                  The address in which to start Gerbil's HTTP server. This should be
                  publicly accessible if Pangolin **is not** running on the same machine.
                '';
                default = "localhost:${gerbil.port}";
                defaultText = "localhost:\${config.services.gerbil.port}";
              };
            };
          };
        };

        environmentFile = mkOption {
          type = nullOr path;
          default = null;
          description = ''
            Path to a file containing environment variables for Gerbil. See the
            Gerbil [README](https://github.com/fosrl/gerbil#environment-variables)
            for more information.

            These will overwrite anything defined in 'services.gerbil.settings'.
          '';
          example = "/etc/gerbil/gerbil.env";
        };
      };

      badger.enable =
        mkEnableOption ''
          Badger, authentication middleware for Traefik, controlled by Pangolin.

          Enabling this as a standalone option is useful if you are manually
          configuring Traefik through NixOS, but not running Gerbil via its
          module
        ''
        // {
          default = gerbil.enable;
          defaultText = literalExpression "config.services.gerbil.enable";
        };
    };

  config =
    let
      httpPorts = [
        80
        443
      ];
      gerbilPorts = [
        21820
        51820
      ];
      internalPorts =
        optional pangolin.enable (
          with pangolin.settings.server;
          [
            internal_port
            external_port
            next_port
            integration_port
          ]
        )
        ++ optional gerbil.enable gerbil.port;

      commonOptions =
        service:
        let
          isPangolin = optionals (service == "pangolin");
          isGerbil = optionals (service == "gerbil");

          mkSystemdList =
            type: allow: strings:
            assert assertOneOf "type" type [
              "capabilities"
              "syscalls"
            ];
            map (
              str: "${optionalString (!allow) "~"}${if type == "syscalls" then "@${str}:EPERM" else "CAP_${str}"}"
            ) strings;

          gerbilNetworkCapabilities = isGerbil (
            mkSystemdList "capabilities" true [
              "NET_ADMIN"
              "SYS_MODULE"
            ]
          );
        in
        assert assertOneOf "service" service [
          "pangolin"
          "gerbil"
        ];
        genAttrs [
          "DynamicUser"
          "LockPersonality"
          "NoNewPrivileges"
          "PrivateDevices"
          "PrivateUsers"
          "PrivateMounts"
          "ProtectClock"
          "ProtectControlGroups"
          "ProtectHome"
          "ProtectHostname"
          "ProtectKernelLogs"
          "ProtectKernelModules"
          "ProtectKernelTunables"
          "RemoveIPC"
          "RestrictRealtime"
          "RestrictSUIDSGID"
        ] (const true)
        // {
          Restart = "always";
          RestartSec = "10s";
          ProtectSystem = "full";
          PrivateTmp = "disconnected";
          ProtectProc = "noaccess";
          StateDirectory = service;
          StateDirectoryMode = "0700";
          MemoryDenyWriteExecute = service == "gerbil";
          SystemCallArchitectures = "native";
          UMask = "0077";
          EnvironmentFile = "${service}".environmentFile;
          RestrictAddressFamilies = map (type: "AF_${type}") [
            "INET"
            "INET6"
            "NETLINK"
            "UNIX"
          ];
          SocketBindDeny = isPangolin (
            mapCartesianProduct ({ version, protocol }: "${version}:${protocol}") {
              version = [
                "ipv4"
                "ipv6"
              ];
              protocol = [
                "tcp"
                "udp"
              ];
            }
          );
          AmbientCapabilities = gerbilNetworkCapabilities;
          CapabilityBoundingSet =
            (mkSystemdList "capabilities" false (
              [
                "BLOCK_SUSPEND"
                "BPF"
                "CHOWN"
                "MKNOD"
                "PERFMON"
                "SYS_BOOT"
                "SYS_CHROOT"
                "SYS_NICE"
                "SYS_PACCT"
                "SYS_PTRACE"
                "SYS_TIME"
                "SYS_TTY_CONFIG"
                "SYSLOG"
                "WAKE_ALARM"
              ]
              ++ isPangolin [
                "SYS_MODULE"
                "NET_RAW"
              ]
            ))
            ++ gerbilNetworkCapabilities;
          SystemCallFilter = mkSystemdList "syscalls" false (
            [
              "chown"
              "clock"
              "cpu-emulation"
              "debug"
              "keyring"
              "memlock"
              "mount"
              "obsolete"
              "pkey"
              "privileged"
              "raw-io"
              "reboot"
              "resources"
              "sandbox"
              "setuid"
              "swap"
              "timer"
            ]
            ++ isPangolin [
              "module"
            ]
            ++ isGerbil [
              "sync"
              "aio"
            ]
          );
        };

      inherit (pangolin.settings) domains;

      wildcardCertsEnabled =
        pangolin.settings.traefik.prefer_wildcard_cert
        || any (attr: attr.prefer_wildcard_cert) (attrValues domains);
    in
    mkMerge [
      (mkIf (pangolin.enable || gerbil.enable) {
        # These are needed regardless if Pangolin or Gerbil are enabled,
        # as they share config options.
        assertions =
          # Assertions for ports.
          (map (
            type:
            let
              illegalPorts =
                if (type == "tcp") then
                  httpPorts ++ optionals pangolin.enable internalPorts
                else if gerbil.enable then
                  gerbilPorts
                else
                  [ ];
            in
            {
              assertion = mutuallyExclusive illegalPorts pangolin.extraPorts.${type};
              message = ''
                'services.pangolin.extraPorts.${type}' contains the following illegal ports:
                - ${concatMapStringsSep "\n- " toString (intersectLists illegalPorts pangolin.extraPorts.${type})}
              '';
            }
          ) (attrNames pangolin.extraPorts))
          ++ [
            {
              assertion = allUnique internalPorts;
              message = ''
                The following ports may have conflicting values:
                - ${
                  concatMapStringsSep "\n- "
                    (port: "services.pangolin.settings.server.${port}: ${toString pangolin.settings.server.${port}}")
                    (
                      pangolin.enable [
                        "internal_port"
                        "external_port"
                        "next_port"
                        "integration_port"
                      ]
                    )
                }
                ${optionalString gerbil.enable "- services.gerbil.port: ${toString gerbil.port}"}
              '';
            }
          ]

          # Assertions for the domain configuration.
          ++ (
            let
              certResolvers = unique ((zipAttrs (attrValues domains)).cert_resolver);
              domainsMappedToResolvers = map (
                resolver:
                attrNames (
                  filterAttrsRecursive (_: domain: isAttrs domain && domain.cert_resolver == resolver) domains
                )
              ) certResolvers;
              allIdentical = list: all (x: (head list) == x) list;
              check =
                attr:
                map (list: allIdentical list) (
                  map (listOfDomain: map (domain: domains.${domain}.${attr}) listOfDomain) domainsMappedToResolvers
                );
              wildcardCheck = check "prefer_wildcard_cert";
              providerCheck = check "_dnsProvider";
              errorAt =
                stage:
                throw "An unexpected error has occured while evaluating the index of the first invalid DNS certificate resolver for the 'nixos/pangolin' module at the '${stage}' stage. Please report this to Nixpkgs.";
            in
            [
              {
                assertion = all (group: group == true) wildcardCheck;
                message = ''
                  The following certificate resolver has conflicting values for the 'prefer_wildcard_cert' option:
                  - ${
                    elemAt certResolvers (
                      findFirstIndex (group: group == false) (errorAt "wildcardCheck") wildcardCheck
                    )
                  }
                '';
              }
              {
                assertion = all (group: group == true) providerCheck;
                message = ''
                  The following certificate resolver has conflicting values for the '_dnsProvider' option:
                  - ${
                    elemAt certResolvers (
                      findFirstIndex (group: group == false) (errorAt "providerCheck") providerCheck
                    )
                  }
                '';
              }
            ]
          )
          ++ (
            let
              allDomains = map (domain: domain.base_domain) (attrValues domains);
            in
            [
              {
                assertion = allUnique allDomains;
                message = ''
                  The following domains may be duplicated in the Pangolin configuration:
                  - ${concatStringsSep "\n- " (subtractLists (unique allDomains) allDomains)}
                '';
              }
              # Check if any domains are unset.
              {
                assertion = all (domain: !isNull domain) allDomains;
                message = ''
                  The following domains are not properly configured in the Pangolin configuration:
                  - '${
                    concatMapStringsSep "\n- '" (name: "services.pangolin.settings.domains.${name}.base_domain': null")
                      (
                        subtractLists (attrNames (filterAttrsRecursive (name: value: !isNull value.base_domain) domains)) (
                          attrNames domains
                        )
                      )
                  }
                '';
              }
            ]
          )
          ++ [
            {
              assertion = domains != { };
              message = ''
                At least one domain must be configured in
                'services.pangolin.settings.domains', but none are available.

                ${
                  if pangolin.settings._dontCreateDefaultDomain then
                    ''
                      This issue has likely occured because
                      'services.pangolin.settings._dontCreateDefaultDomain' is set to
                      'true', and you have not manually configured a domain.
                    ''
                  else
                    ''
                      The '_dontCreateDefaultDomain' hidden option is set to 'false',
                      which should prevent this assertion from triggering under normal
                      circumstances. Please report this issue to Nixpkgs as a bug.
                    ''
                }
              '';
            }
            {
              assertion = wildcardCertsEnabled -> traefik.environmentFiles != [ ];
              message = ''
                You must add your DNS provider's API keys to a Traefik
                environment file using 'services.traefik.environmentFiles' when
                using wildcard certificates.

                See https://docs.digpangolin.com/self-host/advanced/wild-card-domains.
              '';
            }
          ];

        networking.firewall =
          mkIf ((pangolin.enable && pangolin.openFirewall) || (gerbil.enable && gerbil.openFirewall))
            {
              allowedTCPPorts = httpPorts ++ pangolin.extraPorts.tcp;
              allowedUDPPorts = pangolin.extraPorts.udp;
            };

        services.traefik.staticConfigOptions = {
          # Generate DNS certificate resolvers for all domains.
          # The validity checks for these are done at the assertion phase.
          certificatesResolvers =
            let
              mkResolver = domain: {
                acme =
                  (
                    if domain.prefer_wildcard_cert then
                      { dnsChallenge.provider = domain._dnsProvider; }
                    else
                      { httpChallenge.entryPoint = "web"; }
                  )
                  // {
                    email = config.security.acme.defaults.email;
                    storage = "acme.json";
                  };
              };
            in
            mapAttrs' (_: domain: nameValuePair (domain.cert_resolver) (mkResolver domain)) (
              domains // { inherit (pangolin.settings) traefik; }
            );
          entryPoints =
            # Generate TCP/UDP resource entryPoints for the extraPorts.
            (
              genAttrs (mapAttrsToList (protocol: port: protocol + "-" + (toString port)) pangolin.extraPorts) (
                entryPoint:
                let
                  portList = splitString "-" entryPoint;
                  port = last portList;
                  protocol = head portList;
                in
                {
                  address = ":${port}/${protocol}";
                }
              )
            );
        };
      })
      (mkIf pangolin.enable {
        assertions =
          # Pangolin-specific assertions for the domain configuration.
          [
            {
              assertion = elem true baseDomainMatchingDashboardIndexList;
              message = ''
                You have not configured a domain for the dashboard. The
                dashboard is supposed to be available at '${dashboardDomain}',
                but none of the entries in 'services.pangolin.settings.domains'
                configure '${baseDomainForDashboard}'.
              '';
            }

            # Miscellaneous assertions.
            {
              assertion = !isNull pangolin.environmentFile;
              message = ''
                'services.pangolin.environmentFile' must be provided when Pangolin
                is enabled. It should include secrets required by Pangolin, such as
                'SERVER_SECRET' or 'EMAIL_SMTP_PASS'.

                See https://docs.digpangolin.com/self-host/advanced/config-file#environment-variables.
              '';
            }
            {
              assertion = !isNull pangolin.settings.app.dashboard_url;
              message = ''
                You have not configured a dashboard URL for Pangolin.
                Please edit 'services.pangolin.settings.app.dashboard_url'.
              '';
            }

            # We're sidestepping the ACME module, but since we're still using
            # Let's Encrypt for certs, we should still use the same email and ToS
            # assertions.
            {
              assertion = !isNull acme.defaults.email;
              message = ''
                Pangolin depends on the ACME email address to generate
                certificates from Let's Encrypt.

                Please set 'security.acme.defaults.email' to a valid e-mail
                address in order to create an account at Let's Encrypt.
              '';
            }
            {
              assertion = acme.acceptTerms;
              message = ''
                You must accept the Let's Encrypt terms of service before allowing
                Pangolin to generate certificates for you.

                Please review the Let's Encrypt Subscriber Agreement at
                https://letsencrypt.org/repository and set
                'security.acme.acceptTerms' to accept the Subscriber Agreement.
              '';
            }
          ];

        systemd.services.pangolin = {
          description = "Pangolin reverse proxy tunneling service";
          wantedBy = [ "multi-user.target" ];
          requires = [ "network.target" ];
          after = [ "network.target" ];

          preStart =
            let
              # Our 'settings' option includes some Nix-specific options,
              # which all begin with an underscore.
              filteredSettings = filterAttrsRecursive (name: _: !hasPrefix "_" name) pangolin.settings;
              configFile = format.generate "config.yml" filteredSettings;
            in
            "install -D ${configFile} ./config/config.yml";

          serviceConfig = (commonOptions "pangolin") // {
            ExecStart = getExe pangolin.package;
          };
        };

        services.traefik =
          let
            inherit (domains.${dashboardDomainAttrName})
              cert_resolver
              prefer_wildcard_cert
              base_domain
              ;
          in
          {
            enable = true;

            staticConfigOptions.entryPoints = {
              ${pangolin.settings.traefik.http_entrypoint}.address = ":80";
              ${pangolin.settings.traefik.https_entrypoint} = {
                address = ":443";
                transport.respondingTimeouts.readTimeout = "30m";
                http.tls.certResolver = cert_resolver;
              };
            };

            dynamicConfigOptions = {
              http = {
                # The name of this middleware is hardcoded in Pangolin.
                middlewares.redirect-to-https.redirectScheme.scheme = "https";
                routers = {
                  # HTTP to HTTPS redirect router
                  main-app-router-redirect = {
                    rule = "Host(`${dashboardDomain}`)";
                    service = "next-service";
                    entryPoints = [ pangolin.settings.traefik.http_entrypoint ];
                    middlewares = [ "redirect-to-https" ];
                  };
                  # Next.js router (handles everything except API and WebSocket paths)
                  next-router = {
                    rule = "Host(`${dashboardDomain}`) && !PathPrefix(`/api/v1`)";
                    service = "next-service";
                    entryPoints = [ pangolin.settings.traefik.https_entrypoint ];
                    tls =
                      optionalAttrs prefer_wildcard_cert {
                        domains = [
                          { main = base_domain; }
                          { sans = "*.${base_domain}"; }
                        ];
                      }
                      // {
                        certResolver = cert_resolver;
                      };
                  };
                  # API router (handles /api/v1 paths)
                  api-router = {
                    rule = "Host(`${dashboardDomain}`) && PathPrefix(`/api/v1`)";
                    service = "api-service";
                    entryPoints = [ pangolin.settings.traefik.https_entrypoint ];
                    tls.certResolver = cert_resolver;
                  };
                  # WebSocket router
                  ws-router = {
                    rule = "Host(`${dashboardDomain}`)";
                    service = "api-service";
                    entryPoints = [ pangolin.settings.traefik.https_entrypoint ];
                    tls.certResolver = cert_resolver;
                  };
                };
                services = {
                  # Next.JS server (dashboard)
                  next-service.loadBalancer.servers = [
                    {
                      url = "http://localhost:${toString pangolin.settings.server.next_port}";
                    }
                  ];
                  # API/WebSocket server
                  api-service.loadBalancer.servers = [
                    {
                      url = "http://localhost:${toString pangolin.settings.server.external_port}";
                    }
                  ];
                };
              };
            };
          };
      })
      (mkIf gerbil.enable {
        assertions = [
          {
            assertion = badger.enable;
            message = ''
              Badger must be enabled if Gerbil is enabled.
              Please set 'services.badger.enable' to 'true'.
            '';
          }
          {
            assertion = !isNull gerbil.settings.reachableAt;
            message = ''
              'services.gerbil.settings.reachableAt' must be provided when Gerbil
              is enabled.
            '';
          }
          {
            assertion =
              (!isNull gerbil.settings.remoteConfig || !isNull gerbil.settings.config)
              && (isNull gerbil.settings.remoteConfig || isNull gerbil.settings.config);
            message = ''
              Gerbil has ${
                if (!isNull gerbil.settings.remoteConfig && !isNull gerbil.settings.config) then
                  "multiple"
                else if (isNull gerbil.settings.remoteConfig && isNull gerbil.settings.config) then
                  "no"
                else
                  "an unknown issue with its"
              } configuration sources!

              Please correct the values of 'services.gerbil.settings.remoteConfig' or 'services.gerbil.settings.config'.
            '';
          }
        ];

        networking.firewall = mkIf gerbil.openFirewall {
          allowedTCPPorts = optional (!pangolin.enable) gerbil.port;
          allowedUDPPorts = gerbilPorts;
        };

        systemd.services.gerbil = mkMerge [
          (mkIf pangolin.enable {
            after = [ "pangolin.service" ];
            requires = [ "pangolin.service" ];
          })
          {
            description = "Gerbil Service";
            wantedBy = [ "multi-user.target" ];
            before = [ "traefik.service" ];
            requiredBy = [ "traefik.service" ];

            serviceConfig = (commonOptions "gerbil") // {
              ExecStart = "${getExe gerbil.package} ${toGNUCommandLineShell { } gerbil.settings}";
            };
          }
        ];

        services.traefik = {
          enable = true;
          staticConfigOptions = {
            providers = {
              http = {
                endpoint = "${
                  if pangolin.enable then
                    "http://localhost:${toString pangolin.settings.server.internal_port}/api/v1"
                  else
                    removeSuffix "/gerbil/get-config" gerbil.settings.remoteConfig
                }/traefik-config";
                pollInterval = "5s";
              };
            };
          };
        };
      })
      (mkIf badger.enable {
        services.traefik.staticConfigOptions.plugins.badger = {
          moduleName = "github.com/fosrl/badger";
          version = "v1.2.0";
        };
      })
    ];

  meta.maintainers = with maintainers; [
    jackr
    sigmasquadron
  ];
}
