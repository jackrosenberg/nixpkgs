{
  fetchFromGitHub,
  esbuild,
  buildNpmPackage,
  nixosTests,
  nix-update-script
}:

buildNpmPackage rec {
  pname = "pangolin";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "fosrl";
    repo = "pangolin";
    tag = "${version}";
    hash = "sha256-YCXL9UmsuY5qQUqRHbZEF5jrL24CKZMk/cVNW+DkAxI=";
  };

  npmDepsHash = "sha256-1gqmPP1/GVuIbuLW8kUYtdCP0lpvMD2G/Wd38H8hSD0=";
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
    mkdir -p $out/

    cp package.json package-lock.json $out/

    cp -r .next/standalone/* $out/
    cp -r .next/standalone/.next $out/

    cp -r .next/static $out/.next/static
    cp -r dist $out/dist
    cp -r init $out/dist/init

    cp server/db/names.json $out/dist/names.json
    cp -r public $out/public
    cp -r node_modules $out/

  '';
}

