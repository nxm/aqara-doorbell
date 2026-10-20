{
  stdenvNoCC,
  fetchurl,
  unzip,
  lib,
}:

# The prebuilt universal bundle from the GitHub release: the same zip the brew
# cask installs. Building the SwiftUI app inside the Nix sandbox is brittle, and
# release.json (kept current by the release workflow) pins it by hash.
let
  release = lib.importJSON ./release.json;
in
stdenvNoCC.mkDerivation {
  pname = "aqara-doorbell";
  inherit (release) version;

  src = fetchurl {
    url = "https://github.com/nxm/aqara-doorbell/releases/download/v${release.version}/AqaraDoorbell-${release.version}.zip";
    inherit (release) hash;
  };

  # The zip holds AqaraDoorbell.app at the top level; without this Nix would
  # treat the bundle itself as the source root and descend into it.
  sourceRoot = ".";

  nativeBuildInputs = [ unzip ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -R AqaraDoorbell.app $out/Applications/
    runHook postInstall
  '';

  # The bundle is ad-hoc signed; fixup would rewrite the binary and break the
  # signature. Store paths carry no quarantine flag, so Gatekeeper lets it run.
  dontFixup = true;

  meta = {
    description = "Unofficial menu-bar client for the Aqara G410 video doorbell";
    homepage = "https://github.com/nxm/aqara-doorbell";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.platforms.darwin;
  };
}
