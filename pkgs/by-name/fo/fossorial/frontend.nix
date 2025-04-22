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
    next build
    node esbuild.mjs -e server/index.ts -o dist/server.mjs
    node esbuild.mjs -e server/setup/migrations.ts -o dist/migrations.mjs

    runHook postBuild
  '';

  # TODO: cleanup
  installPhase = ''
    runHook preInstall

    mkdir -p $out/.next/

    echo "ls -a:"
    ls -a

    echo "ls -a .next"
    ls -a .next

    cp -r .next/standalone $out/
    cp -r .next/static $out/.next/static
    cp -r dist $out/dist
    cp -r init $out/dist/init

    cp server/db/names.json $out/dist/names.json
    cp -r public $out/public

    cp -r node_modules $out/

    runHook postInstall
  '';

    # runHook preInstall
    #
    # mkdir -p $out/
    # cp -r * $out/
    #
    # echo "next: ---------------------"
    # ls -a .next
    # cp -r .next/standalone $out/
    # cp -r .next/ $out/
    #
    # mkdir -p $out/config/db
    # mkdir $out/config/traefik
    #
    # cp -r $out/init $out/dist
    # cp $out/server/db/names.json $out/dist/names.json
    #
    # runHook postInstall
}
