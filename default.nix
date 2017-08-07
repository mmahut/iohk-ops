let
  localLib = import ./lib.nix;
in
{ system ? builtins.currentSystem
, config ? {}
, pkgs ? (import (localLib.fetchNixPkgs) { inherit system config; })
, compiler ? pkgs.haskell.packages.ghc802
}:

with pkgs.lib;
with (import <nixpkgs/pkgs/development/haskell-modules/lib.nix> { inherit pkgs;});

let
  prodMode = addConfigureFlags [ "-f-asserts" "-f-dev-mode" "--ghc-options=-DCONFIG=testnet_staging"];
  addConfigureFlags = flags: drv: overrideCabal drv (drv: {
    configureFlags = flags;
  });

  socket-io-src = pkgs.fetchgit (removeAttrs (importJSON ./pkgs/engine-io.json) ["date"]);
  iohkpkgs = ((import pkgs/default.nix { inherit pkgs compiler; }).override {
  overrides = self: super: {
    cpphs = compiler.cpphs;
    cardano-sl-core = prodMode super.cardano-sl-core;
    cardano-sl = overrideCabal super.cardano-sl (drv: {
      doHaddock = false;
      patchPhase = ''
       export CSL_SYSTEM_TAG=linux64
      '';
      # production full nodes shouldn't use wallet as it means different constants
      configureFlags = [
        "-f-asserts"
        "-f-dev-mode"
        "-fwith-explorer"
        # https://github.com/NixOS/nixpkgs/pull/24692#issuecomment-306509337
        "--ghc-option=-optl-lm"
      ];
    });
    cardano-sl-static = justStaticExecutables self.cardano-sl;
    cardano-report-server-static = justStaticExecutables self.cardano-report-server;

    # TODO: https://github.com/input-output-hk/stack2nix/issues/7
    ether = addConfigureFlags ["-fdisable-tup-instances"] super.ether;

    # Gold linker fixes
    cryptonite = addConfigureFlags ["--ghc-option=-optl-pthread"] super.cryptonite;


    # sl-explorer
    # TODO: https://issues.serokell.io/issue/CSM-195
    snap = doJailbreak super.snap;
    # TODO: https://github.com/input-output-hk/stack2nix/issues/10
    socket-io = self.callPackage ./pkgs/socket-io.nix {};
    engine-io = self.callPackage ./pkgs/engine-io.nix {};
    engine-io-wai = self.callPackage ./pkgs/engine-io-wai.nix {};

    cardano-sl-explorer = prodMode (super.callPackage ./pkgs/cardano-sl-explorer.nix { });
    cardano-sl-explorer-static = justStaticExecutables self.cardano-sl-explorer;

    #mkDerivation = args: super.mkDerivation (args // {
    #enableLibraryProfiling = false;
    #});
  };
});
  iohk-ops-extra-runtime-deps = [
    pkgs.git pkgs.nix-prefetch-scripts
  ];
  cabal2nixpkgs = rec {
    # extra packages to expose, that have no relation to pkgs/default.nix
    stack2nix = import (pkgs.fetchFromGitHub {
      owner = "input-output-hk";
      repo = "stack2nix";
      rev = "c2a9c293d92790054fa1d3299341cfd4fac741b3";
      sha256 = "18k4yh9b1115h0x30fzfs8a4zb3dav57ywn5wx2axh5r2ybfm6v8";
    });
    iohk-ops = pkgs.haskell.lib.overrideCabal
               (compiler.callPackage ./pkgs/iohk-ops.nix {})
               (drv: {
                  executableToolDepends = [ pkgs.makeWrapper ];
                  postInstall = ''
                    wrapProgram $out/bin/iohk-ops \
                    --prefix PATH : "${pkgs.lib.makeBinPath iohk-ops-extra-runtime-deps}"
                  '';
               });
  };
in iohkpkgs // cabal2nixpkgs
