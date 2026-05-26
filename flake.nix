{
  description = "Darnix — boot XNU from Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";

    # Versions taken from apple-oss-distributions/distribution-macOS@rel/macOS-26 release.json
    xnu-src                  = { url = "github:jonhermansen/xnu/nix"; flake = false; };
    bootstrap_cmds-src       = { url = "github:apple-oss-distributions/bootstrap_cmds/bootstrap_cmds-138"; flake = false; };
    dtrace-src               = { url = "github:apple-oss-distributions/dtrace/dtrace-413"; flake = false; };
    AvailabilityVersions-src = { url = "github:apple-oss-distributions/AvailabilityVersions/AvailabilityVersions-157.2"; flake = false; };
    Libsystem-src            = { url = "github:apple-oss-distributions/Libsystem/Libsystem-1356"; flake = false; };
    libplatform-src          = { url = "github:apple-oss-distributions/libplatform/libplatform-375.100.10"; flake = false; };
    libdispatch-src          = { url = "github:apple-oss-distributions/libdispatch/libdispatch-1542.100.32"; flake = false; };
    grub-src = {
      url = "github:jonhermansen/grub/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hfs-src                  = { url = "github:jonhermansen/hfs/nix"; flake = false; };
    qemu-src = {
      url = "github:jonhermansen/qemu/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
};

  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        qemu = inputs.qemu-src.packages.${system}.qemu;
      in
        import ./nix {
          inherit pkgs inputs system qemu;
          buildScriptSrc = let
            root = toString ./.;
            allowed = [ "build.sh" "codeql.sh" "patches" "Makefile" "templates" ];
          in pkgs.lib.cleanSourceWith {
            src = ./.;
            filter = path: type:
              let
                rel = pkgs.lib.removePrefix (root + "/") path;
                top = builtins.head (pkgs.lib.splitString "/" rel);
              in builtins.elem top allowed;
          };
        }
    );
}
