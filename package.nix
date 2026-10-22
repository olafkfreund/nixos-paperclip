{
  lib,
  buildNpmPackage,
  fetchurl,
  jq,
  makeWrapper,
  nodejs_24,
}:

buildNpmPackage rec {
  pname = "paperclip";
  version = "2026.1005.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/@paperclipai/server/-/server-${version}.tgz";
    hash = "sha256-lxTrvF1si9sHUopKKkoOCWb8ItxdSGigzLbfHgHoklY=";
  };

  nodejs = nodejs_24;
  nativeBuildInputs = [ makeWrapper ];

  # The unpublished devDependency @paperclipai/paperclip-runner (vendored in dist/) breaks
  # npm resolution, so drop devDependencies; package-lock.json was generated the same way.
  postPatch = ''
    ${lib.getExe jq} 'del(.devDependencies)' package.json > package.json.new
    mv package.json.new package.json
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-/+H3aqMnQLMKaJsZQHm7VP2F4mo42nia4XypIgebfX8=";
  npmFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall
    dir=$out/lib/node_modules/@paperclipai/server
    mkdir -p $dir $out/bin
    cp -r . $dir
    makeWrapper ${lib.getExe nodejs_24} $out/bin/paperclip-server \
      --add-flags $dir/dist/index.js \
      --set-default NODE_ENV production
    runHook postInstall
  '';

  meta = {
    description = "Paperclip agent orchestration server";
    homepage = "https://github.com/paperclipai/paperclip";
    license = lib.licenses.mit;
    mainProgram = "paperclip-server";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
