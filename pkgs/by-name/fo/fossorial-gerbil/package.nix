{
  fetchFromGitHub,
  buildGoModule
}:

buildGoModule rec {
  pname = "fosrl-gerbil";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "fosrl";
    repo = "gerbil";
    tag = "${version}";
    hash = "sha256-6ZmnokXmn4KIfNZT9HrraYP4fjfY2C0sK+xAJyq/pkU=";
  };

  vendorHash = "sha256-lYJjw+V94oxILu+akUnzGACtsU7CLGwljysRvyUk+yA=";
}
