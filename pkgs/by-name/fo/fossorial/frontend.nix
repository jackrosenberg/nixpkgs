{
  lib,
  esbuild,
  buildNpmPackage,

  pname,
  version,
  src,
  npmDepsHash,
}:

buildNpmPackage {
  inherit version src npmDepsHash;
  pname = "${pname}-frontend";

  nativeBuildInputs = [ esbuild ];
  # fix the dependency on google fonts
  patches = [ ./dep.patch ];
  buildPhase = ''
    runHook preBuild

    mkdir -p dist
    npx next build
    node esbuild.mjs -e server/index.ts -o dist/server.mjs
    node esbuild.mjs -e server/setup/migrations.ts -o dist/migrations.mjs

    ls -a

    runHook postBuild
  '';

  # installPhase = ''
  #   runHook preInstall
  #
  #   mkdir -p $out/
  #   cp -r dist $out/
  #   cp -r config $out/config
  #   cp -r node_modules $out/node_modules
  #
  #   runHook postInstall
  # '';
  installPhase = ''
    runHook preInstall

    mkdir -p $out/
    cp -r * $out/
    mkdir $out/config/traefik

    runHook postInstall
  '';
}
