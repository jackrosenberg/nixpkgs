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

    npx drizzle-kit generate --dialect sqlite --schema ./server/db/schemas/ --out init

    mkdir -p dist
    npx next build
    node esbuild.mjs -e server/index.ts -o dist/server.mjs
    node esbuild.mjs -e server/setup/migrations.ts -o dist/migrations.mjs

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
  # TODO: cleanup
  installPhase = ''
    runHook preInstall

    mkdir -p $out/
    cp -r * $out/
    mkdir $out/config/traefik

    cp -r $out/init $out/dist

    runHook postInstall
  '';
}
