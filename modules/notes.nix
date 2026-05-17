{ inputs, self, ... }:

{
  flake.homeModules.notes =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      programs.obsidian = {
        enable = true;
      };
    };
  # flake.nixosModules."homelab-notes" =
  #   {
  #     config,
  #     pkgs,
  #     lib,
  #     noughtyLib,
  #     ...
  #   }:
  #   let
  #     memos-0_27_1 = pkgs.callPackage (
  #       {
  #         fetchFromGitHub,
  #         buildGoModule,
  #         stdenvNoCC,
  #         nodejs,
  #         fetchPnpmDeps,
  #         pnpmConfigHook,
  #         pnpm,
  #       }:
  #       let
  #         version = "0.27.1";
  #         src = fetchFromGitHub {
  #           owner = "usememos";
  #           repo = "memos";
  #           rev = "v${version}";
  #           hash = "sha256-HEQeMsUVvmrnW3pvTzMGIlCl8B9UuwnlyU8U0r1aRSc=";
  #         };

  #         memos-web = stdenvNoCC.mkDerivation (finalAttrs: {
  #           pname = "memos-web";
  #           inherit version src;
  #           pnpmDeps = fetchPnpmDeps {
  #             inherit (finalAttrs) pname version src;
  #             sourceRoot = "${finalAttrs.src.name}/web";
  #             fetcherVersion = 3;
  #             hash = "sha256-NTPP9nHAtiTmIUpchxAvWLN6s99UKVXF7E+Z4JpiFT8=";
  #           };
  #           pnpmRoot = "web";
  #           nativeBuildInputs = [
  #             nodejs
  #             pnpmConfigHook
  #             pnpm
  #           ];
  #           buildPhase = ''
  #             runHook preBuild
  #             pnpm -C web build
  #             runHook postBuild
  #           '';
  #           installPhase = ''
  #             runHook preInstall
  #             cp -r web/dist $out
  #             runHook postInstall
  #           '';
  #         });
  #       in
  #       buildGoModule {
  #         pname = "memos";
  #         inherit version src;

  #         vendorHash = "sha256-QNJosdRo1DauCOGFB+GrasSoKSmRhc3EjRfjm4TG0Jo=";

  #         ldflags = [
  #           "-X github.com/usememos/memos/internal/version.Version=${version}"
  #         ];

  #         preBuild = ''
  #           rm -rf server/router/frontend/dist
  #           cp -r ${memos-web} server/router/frontend/dist
  #         '';

  #         doCheck = false;

  #         meta = {
  #           homepage = "https://usememos.com";
  #           description = "Lightweight, self-hosted memo hub";
  #           license = lib.licenses.mit;
  #           mainProgram = "memos";
  #         };
  #       }
  #     ) { };
  #   in
  #   lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
  #     services.memos = {
  #       enable = true;
  #       package = memos-0_27_1;
  #     };
  #     phonkds.modules = {
  #       notes = {
  #         ip = "127.0.0.1";
  #         port = 5230;
  #         dashboard = {
  #           enable = true;
  #           icon = "memos";
  #         };
  #         traefik = {
  #           enable = true;
  #           auth = false;
  #           domain = "memos.int.w.phonkd.net";
  #           ipfilter = true;
  #         };
  #       };
  #     };
  #   };
}
