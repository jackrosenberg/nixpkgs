{
  options,
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.types)
    attrsOf
    listOf
    nullOr
    path
    str
    submodule
    package
    ;
  inherit (lib)
    attrByPath
    concatMapStringsSep
    converge
    filter
    filterAttrsRecursive
    getExe
    id
    literalExpression
    mapAttrs'
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    mkRenamedOptionModule
    mkRemovedOptionModule
    nameValuePair
    optional
    optionalAttrs
    recursiveUpdate
    splitStringBy
    types
    ;

  cfg = config.services.traefik;
  opt = options.services.traefik;
  json = pkgs.formats.json { };

  # check if the option has been changed
  ## isDefault :: String -> bool
  ## eg. isDefault "install.settings" == (cfg.install.settings == opt.install.settings.default)
  isDefault =
    attrPathStr:
    let
      sepPath = splitStringBy (prev: curr: builtins.elem curr [ "." ]) false attrPathStr;
    in
    attrByPath (sepPath ++ [ "default" ]) (throw "isDefault failed") opt
    == attrByPath sepPath (throw "isDefault failed") cfg;

  # JSON is considered valid YAML by Traefik.
in
{
  imports = [
    (mkRemovedOptionModule
      [
        "services"
        "traefik"
        "useEnvSubst"
      ]
      # TODO link or mention docs
      "Use `services.traefik.environmentFiles` instead, see docs"
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "staticConfigFile"
      ]
      [
        "services"
        "traefik"
        "install"
        "file"
      ]
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "staticConfigOptions"
      ]
      [
        "services"
        "traefik"
        "install"
        "settings"
      ]
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "dynamicConfigFile"
      ]
      [
        "services"
        "traefik"
        "routing"
        "file"
      ]
    )
    (mkRenamedOptionModule
      [
        "services"
        "traefik"
        "dynamicConfigOptions"
      ]
      [
        "services"
        "traefik"
        "routing"
        "settings"
      ]
    )
  ];
  options.services.traefik = {
    enable = mkEnableOption "Traefik web server";
    package = mkPackageOption pkgs "traefik" { };

    install = {
      file = mkOption {
        default = json.generate "install_config.json" (
          # converge is needed to fully remove entire trees of empty attribute sets
          converge (
            # remove `null` (used for comparisons of unset values)
            # and `{}` or `[]`, which is left behind by type checked submodule options
            filterAttrsRecursive (_: val: val != null && val != { } && val != [ ])
          ) cfg.install.settings
        );
        example = literalExpression "/path/to/install_config.yml";
        type = path;
        # Ideally default option values would instead be filtered by `options.<option>.highestPrio == (lib.mkOptionDefault {}).priority`
        # TODO exclusivity warning wording
        # TODO explain that this is passed as `--configfile`
        description = ''
          Path to Traefik's install configuration file.

          ::: {.note}
          You cannot use this option alongside the declarative install configuration options.
          :::
        '';
      };
      settings = mkOption {
        # TODO add note about `{}` and `null` being filtered, and what to do instead (rather than `{}`, use `true`)
        description = ''
          Install configuration for Traefik, written in Nix.

          ::: {.note}
          This will be serialized to JSON (which is considered valid YAML) at build, and passed to Traefik as `--configfile`.
          :::
        '';
        type = types.submodule {
          freeformType = json.type;
          options = {
            providers = {
              file = {
                filename = mkOption {
                  default = cfg.routing.file;
                };
                directory = mkOption {
                  default = cfg.routing.dir;
                };
              };
            };
            # TODO make sure this properly replaces `mkIf` statement as intended
            experimental.localPlugins = mkOption {
              default =
                if (cfg.localPlugins != [ ]) then
                  lib.listToAttrs (
                    map (plugin: lib.nameValuePair plugin.plugin { inherit (plugin) moduleName; }) cfg.localPlugins
                  )
                else
                  [ ];
            };
          };
        };
        default = { };
        example = {
          entryPoints = {
            "web" = {
              address = ":80";
              http.redirections.entryPoint = {
                permanent = true;
                scheme = "https";
                to = "websecure";
              };
            };
            "websecure" = {
              address = ":443";
              asDefault = true;
            };
          };
        };
      };

    };

    routing = {
      file = mkOption {
        default = if (cfg.routing.finalSettings != null) then "/etc/traefik/routing.yml" else null;
        example = literalExpression "/path/to/routing_config.yml";
        type = nullOr path;
        #TODO polish/formatting
        description = ''
          Path to Traefik's routing configuration file.

          ::: {.note}
          You cannot use this option alongside the declarative routing configuration options.
          :::
          ::: {.note}
          If declarative routing configuration has been set, it will automatically be serialized to JSON (which is considered valid YAML) at build
          and linked to `/etc/traefik.routing.yml`. The file permissions and directories will be set automatically if `user == traefik`, otherwise
          you are responsible for ensuring those are set before the traefik service starts.
          :::
          ::: {.note}
          To avoid this behaviour entirely, prefer setting `install.settings.providers.file.*` directly instead
          :::
        '';
      };
      dir = mkOption {
        default = null;
        example = literalExpression "/etc/traefik/routing";
        type = nullOr path;
        #TODO add warning for exclusivity, relevant documentation
        description = ''
          Path to the directory Traefik should watch for configuration files.

          ::: {.warning}
          Files in this directory matching the glob `_nixos-*` (reserved for Nix-managed routing configurations) will be deleted as part of
          `systemd-tmpfiles-resetup.service`, _**regardless of their origin.**_.
          :::
        '';
      };
      extraFiles = mkOption {
        type = attrsOf (submodule {
          options.settings = mkOption {
            type = json.type;
            #TODO fix note,
            #TODO mention auto merge
            description = ''
              Routing configuration for Traefik, written in Nix.

              ::: {.note}
              This will be serialized to JSON (which is considered valid YAML) at build, and passed as part of the install file.
              :::
            '';
            example = {
              http.routers."api" = {
                service = "api@internal";
                rule = "Host(`localhost`)";
              };
            };
          };
        });
        default = { };
        example = {
          "dashboard".settings = {
            http.routers."api" = {
              service = "api@internal";
              rule = "Host(`198.51.100.1`)";
            };
          };
        };
        # TODO process `extraFiles` and/or `finalSettings` and validate by json schema,
        # schema available at schemastore.org
        description = ''
          Routing configuration files to write. These are symlinked in `services.traefik.routing.dir` upon activation,
          allowing configuration to be upated without restarting the primary daemon.

          ::: {.note}
          Due to [a limitation in Traefik](https://github.com/traefik/traefik/issues/10890); a syntax error in _**any**_ routing configuration will cause the _**entire file provider**_ to be ignored.
          This may cause interuption in service, which may include access to the Traefik dashboard, if [enabled and configured](https://doc.traefik.io/traefik/reference/install-configuration/api-dashboard/).
          :::
        '';
      };

      finalSettings = mkOption {
        type = json.type;
        readOnly = true;
        description = ''
          Final declarative routing configuration. If `cfg.routing.settings` is declared, this will contain it.
          If `cfg.routing.extraFiles` is declared but `cfg.routing.dir` is not, the contents of `cfg.routing.extraFiles.*.settings`
          will be merged with `cfg.routing.settings.
          This allows other modules to write `enableTraefik` options which are compatible with both `cfg.routing.extraFiles` and `cfg.routing.settings`

          :: note Modules implementing an `enableTraefik` option should list the following in the options description:
          - The names of `services` added
          - The names of `extraFiles` created
          - Whether they provide a router or service only (depends on whether the nixosModule has the information needed to create one)
        '';
        default =
          if (cfg.routing.settings != null) then
            json.generate "traefik-routing-settings.yml" (
              recursiveUpdate cfg.routing.settings (
                optionalAttrs (cfg.routing.extraFiles != { } && cfg.routing.dir == null) lib.foldAttrs (
                  item: acc: recursiveUpdate item acc
                ) { } (lib.mapAttrsToList (name: value: value.settings) cfg.routing.extraFiles)
              )
            )
          else
            null;
      };
      settings = mkOption {
        type = json.type;
        description = ''
          Routing configuration for Traefik, written in Nix.
        '';
        default = null;
        example = {
          http.routers."api" = {
            service = "api@internal";
            rule = "Host(`localhost`)";
          };
        };
      };
    };
    localPlugins = mkOption {
      default = [ ];
      type = listOf package;
      example = literalExpression "[ pkgs.fosrl-badger pkgs.geoblock ]";
      description = ''
        List of local plugins to be added to the `localPlugins` attribute in the install configuration. These plugins are usually packaged in Nixpkgs, and are managed by Nix.
      '';
    };

    dataDir = mkOption {
      # TODO Was this /var/lib before?
      default = "/etc/traefik";
      type = path;
      description = ''
        Location for any persistent data Traefik creates, such as the ACME certificate store.

        ::: {.note}
        If left as the default value, this directory will automatically be created
        before the Traefik server starts, otherwise you are responsible for ensuring
        the directory exists with appropriate ownership and permissions.
        :::
      '';
    };

    user = mkOption {
      default = "traefik";
      type = str;
      description = ''
        User under which Traefik runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the Traefik service starts.
        :::
      '';
    };

    group = mkOption {
      default = "traefik";
      type = str;
      description = ''
        Primary group under which Traefik runs.
        For the Docker backend, use {option}`services.traefik.supplementaryGroups` instead of overriding this option.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the Traefik service starts.
        :::
      '';
    };

    supplementaryGroups = mkOption {
      default = [ ];
      type = listOf str;
      example = [ "docker" ];
      description = ''
        Additional groups under which Traefik runs.
        This can be used to give additional permissions, such as the group required by the `docker` provider.

        ::: {.note}
        With the `docker` provider, Traefik manages connection to containers via the Docker socket,
        which requires membership of the `docker` group for write access.
        :::
      '';
    };

    environmentFiles = mkOption {
      default = [ ];
      type = listOf path;
      example = [ "/run/secrets/traefik.env" ];
      # TODO make sure this covers all use cases, give instructions on how to reference
      # an environment variable from within the traefik install/routing config if applicable
      description = ''
        Files to load as an environment file just before Traefik starts.
        This can be used to pass secrets such as [DNS challenge API tokens](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/#providers) or [ENV variables](https://doc.traefik.io/traefik/reference/install-configuration/boot-environment/#environment-variables).
        ```
        DESEC_TOKEN=
        TRAEFIK_CERTIFICATESRESOLVERS_<NAME>_ACME_EAB_HMACENCODED=
        TRAEFIK_CERTIFICATESRESOLVERS_<NAME>_ACME_EAB_KID=
        ```
        ::: {.warn}
        The traefik install configuration methods (env, CLI, and file) are mutually exclusive.
        :::
        ```
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # TODO ensure this works with install.settings being a submodule
        assertion = (!(isDefault "install.file")) -> isDefault "install.settings";
        message = ''
          The 'services.traefik.install.file' and 'services.traefik.install.settings'
          options are mutually exclusive for the Traefik install config.
          It is recommended to use 'settings'.
        '';
      }
      {
        assertion =
          (!(isDefault "install.file"))
          -> (builtins.all (
            map isDefault [
              "routing.extraFiles"
              "routing.dir"
              "routing.file"
            ]
          ));
        message = ''
          None of the routing configuration options may be used if Traefik is being managed imperatively.
          The following options have non-default values:
            - ${
              concatMapStringsSep "\n  - " (str: "'services.traefik.routing.${str}'") (
                filter (attr: !(isDefault "routing.${attr}")) [
                  "extraFiles"
                  "dir"
                  "file"
                  "settings"
                ]
              )
            }
        '';
      }
      {
        assertion = !(isDefault "routing.file") -> cfg.routing.dir == null;
        message = ''
          The 'services.traefik.routing.file' and 'services.traefik.routing.dir' options
          are mutually exclusive for the Traefik routing config. It is recommended to use
          'services.traefik.routing.dir' with 'services.traefik.routing.extraFiles'.
        '';
      }
      {
        assertion =
          cfg.routing.extraFiles != { } && cfg.routing.settings == null -> cfg.routing.dir != null;
        message = ''
          'services.traefik.routing.extraFiles' requires the routing file provider to be set
          to a directory. Please set a path for 'services.traefik.routing.dir'.
        '';
      }
      {
        assertion = cfg.group != "docker";
        message = ''
          Setting the primary group to 'docker' will cause files, such as those generated
          by 'services.traefik.routing.extraFiles', to be owned by the group 'docker', which
          may be a security risk. Use 'services.traefik.supplementaryGroups' instead.
        '';
      }
    ];

    warnings =
      optional (!(builtins.elem "docker" cfg.supplementaryGroups -> config.virtualisation.docker.enable))
        "'services.traefik.supplementaryGroups' contains the 'docker' group, but 'services.docker' is not enabled."
        # TODO check for functionality as intended
      ++ optional (!builtins.all id (map (plugin: plugin._isTraefikPlugin or false) cfg.localPlugins)) ''
        Some of the Traefik local plugins in 'services.traefik.localPlugins' may be misconfigured.
        The following paths are built from derivations that do not have the '_isTraefikPlugin' attribute set to 'true':
        - ${
          concatMapStringsSep "\n- " (badPlugin: badPlugin.outPath) (
            filter (plugin: plugin._isTraefikPlugin or false) cfg.localPlugins
          )
        }
      '';

    # TODO ensure this is applicable/helpful
    # https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
    boot.kernel.sysctl = {
      "net.core.rmem_max" = 2500000;
      "net.core.wmem_max" = 2500000;
    };

    systemd.services.traefik = {
      description = "Traefik reverse proxy";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 86400;
      startLimitBurst = 5;
      unitConfig.Documentation = "https://doc.traefik.io/traefik/";
      serviceConfig = {
        EnvironmentFile = cfg.environmentFiles;
        ExecStart = "${getExe cfg.package} --configfile=${cfg.install.file}";
        Type = "notify";
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = mkIf (cfg.supplementaryGroups != [ ]) cfg.supplementaryGroups;
        Restart = "always";
        AmbientCapabilities = "cap_net_bind_service";
        CapabilityBoundingSet = "cap_net_bind_service";
        NoNewPrivileges = true;
        TasksMax = 64;
        LimitNOFILE = 1048576;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths = optional (cfg.routing.dir != null) cfg.routing.dir;
        RuntimeDirectoryMode = "0700";
        RuntimeDirectory = "traefik";
        WorkingDirectory = cfg.dataDir;
        WatchdogSec = "1s";
      };
    };

    # TODO review mkIf statements to ensure cfg.{user, group} logic functions as expected
    systemd.tmpfiles.settings."10-traefik" = mkMerge [
      (mkIf (cfg.user == "traefik") {
        ${cfg.dataDir}.d = {
          inherit (cfg) user group;
          mode = "0700";
        };
      })
      (mkIf (cfg.routing.finalSettings != null) {
        "/etc/traefik/routing.yml"."L+" = {
          mode = "0444";
          argument = toString cfg.routing.finalSettings;
        };
      })
      (mkIf (cfg.user == "traefik" || cfg.group == "traefik") {
        ${cfg.routing.dir}.d = {
          user = mkIf (cfg.user == "traefik") cfg.user;
          group = mkIf (cfg.group == "traefik") cfg.group;
          mode = "0700";
        };
      })
      (mkIf (cfg.routing.dir != null) (
        {
          # Remove previous declarative routing configuration files
          "${cfg.routing.dir}/_nixos-*".r = { };
        }
        // (mapAttrs' (
          name: value:
          nameValuePair "${cfg.routing.dir}/_nixos-${name}.yml" {
            "L+" = {
              mode = "0444";
              argument = toString (json.generate name value.settings);
            };
          }
        ) cfg.routing.extraFiles)
      ))
      # TODO needs user/group checks
      # TODO does this need to point to the install setting instead?
      (mkIf (cfg.localPlugins != [ ]) {
        "${cfg.dataDir}/plugins-local"."L+" = {
          inherit (cfg) user group;
          mode = "0700";
          argument = toString (
            pkgs.symlinkJoin {
              name = "traefik-plugins";
              paths = cfg.localPlugins;
            }
          );
        };
      })
    ];

    users = {
      users = optionalAttrs (cfg.user == "traefik") {
        traefik = {
          inherit (cfg) group;
          isSystemUser = true;
        };
      };
      groups = optionalAttrs (cfg.group == "traefik") { traefik = { }; };
    };
  };

  meta = {
    maintainers = with lib.maintainers; [
      jackr
      therealgramdalf
    ];
    doc = ./traefik.md;
  };
}
