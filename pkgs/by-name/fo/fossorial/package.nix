{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  callPackage,
  nixosTests,
  nix-update-script
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pangolin";
  version = "1.2.0";

  src = fetchFromGitHub {
    owner = "fosrl";
    repo = "pangolin";
    tag = "${finalAttrs.version}";
    hash = "sha256-2yrim4pr8cgIh/FBuGIuK+ycwImpMiz+m21H5qYARmU=";
  };

  npmDepsHash = "sha256-fi4e79Bk1LC/LizBJ+EhCjDzLR5ZocgVyWbSXsEJKdw=";

  frontend = callPackage ./frontend.nix {
    inherit (finalAttrs)
      pname
      version
      src
      npmDepsHash
      ;
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir $out
    ln -s ${finalAttrs.frontend}/* $out/
    ln -s ${finalAttrs.frontend}/.* $out/

    runHook postInstall
  '';
})
