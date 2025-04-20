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
  preBuild = ''
    ls -a
  '';
  buildPhase = ''
    runHook preBuild

    mkdir -p dist
    npx next build
    node esbuild.mjs -e server/index.ts -o dist/server.mjs
    node esbuild.mjs -e server/setup/migrations.ts -o dist/migrations.mjs

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r dist ssr.js favicon.png robots.txt $out/

    runHook postInstall
  '';

}
