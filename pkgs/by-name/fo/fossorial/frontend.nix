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
    npm run build

    runHook postBuild
  '';

  # TODO: cleanup
  installPhase = ''
    runHook preInstall

    mkdir -p $out/

    cp package.json package-lock.json $out/

    cp -r .next/standalone/* $out/
    cp -r .next/standalone/.next $out/

    cp -r .next/static $out/.next/static
    cp -r dist $out/dist
    cp -r init $out/dist/init

    cp -r public $out/public
    cp -r node_modules $out/

    runHook postInstall
  '';
}
