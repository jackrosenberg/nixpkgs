{
  fetchFromGitHub,
  buildGoModule
}:

buildGoModule rec {
  pname = "fosrl-newt";
  version = "1.1.3";

  src = fetchFromGitHub {
    owner = "fosrl";
    repo = "newt";
    tag = "${version}";
    hash = "sha256-wfm2UI4QUiYiAJIYBiSCOD/w72WRJIv2cyLIkfqGsek=";
  };

  vendorHash = "sha256-8VlT9cy2uNhQPiUpr1jJuQSgUR6TtlbQ+etran2Htxs=";
}
