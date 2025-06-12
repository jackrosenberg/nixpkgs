{ lib, pkgs, ... }:
let
  domain = "example.test";
  # needs to be created
  apiKey = ""; # TODO UPSTREAM
  subnet = "100.90.128.0/24";
  address = "100.90.128.0";
  pubKey = "this.is.the.public.key";
  newtId = "this.is.the.newt.id";
  secret = "1234567890";

  headers = ''
    curl -X 'PUT' \
    'http://localhost:3003/v1/org' \
    -H 'accept: */*' \
    -H 'Authorization: Bearer ${apiKey}' \
    -H 'Content-Type: application/json' \
  '';
  orgCreateCmd = headers + ''
    -d '{
      "orgId": "test",
      "name": "test",
      "subnet": ${subnet}
    }'
  '';
  siteCreateCmd = headers + ''
      -d '{
        "name": "test_site",
        "exitNodeId": 1,
        "pubKey": ${pubKey},
        "subnet": ${subnet},
        "newtId": ${newtId},
        "secret": ${secret},
        "address": ${address},
        "type": "newt"
      }'
  '';
in
rec {
  name = "pangolin";
  meta.maintainers = with lib.maintainers; [ jackr ];

  nodes = {

    VPS = {
      imports = [ ./common/acme/client ];
      networking.domain = domain;

      environment = {
        etc."nixos/secrets/pangolin.env".text = ''
          SERVER_SECRET=${secret}
        '';
        systemPackages = [ pkgs.fosrl-pangolin ];

      };
      services.pangolin = {
        enable = true;
        baseDomain = domain;
        letsEncryptEmail = "email@${domain}";
        openFirewall = true;
        pangolinEnvironmentFile = "/etc/nixos/secrets/pangolin.env";
      };
    };

    privateHost = {
      # TODO, check if this is correct.
      # API is unclear on what's what
      environment.etc."nixos/secrets/newt.env".text = ''
        NEWT_ID=${newtId}
        NEWT_SECRET=${secret}
      '';
      services.newt = {
        enable = true;
        endpoint = domain;
        environmentFile = "/etc/secrets/nixos/newt.env"; # TODO
      };
    };

    # Fake ACME server which will respond to client requests
    acme =
      { nodes, ... }:
      {
        imports = [ ./common/acme/server ];
      };
  };
  # general idea:
  # Panglin on the VPS, and Newt in the privateHost
  # setup ACME server to sign certificates and point
  # DNS to the correct machine
  testScript = ''
    # import pathlib
    # import os
    #
    VPS.start()
    privateHost.start()

    with subtest("start pangolin"):
      VPS.wait_for_unit("pangolin.service")

    with subtest("create APIKEY"):
      # maybe not even needed
      VPS.execute("pangctl set-admin-credentials --email \"admin@example.test\" --password \"Password123!\"")
      # VPS.execute("echo 'this is where i would put my pangctl create key, IF I HAD ONE'", )
      # VPS.wait_for_unit("pangolin.service")

    with subtest("create org and site"):
      VPS.execute(${orgCreateCmd})
      VPS.execute(${siteCreateCmd})

    # TODO
    # with subtest("check org exists"):
      # VPS.succeed("curl -X 'GET' 'https://pangolin.${nodes.VPS.services.pangolin.baseDomain}/v1/orgs?limit=1000&offset=0' -H 'accept: */*' -H 'Authorization: Bearer ${apiKey}'")


  '';
}
