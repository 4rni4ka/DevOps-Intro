{
  description = "Reproducible QuickNotes binary and container image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      quicknotes = pkgs.buildGoModule {
        pname = "quicknotes";
        version = "0.1.0";
        src = ./app;
        # app/go.mod has no external modules: Nix requires null for an empty vendor tree.
        vendorHash = null;
        env.CGO_ENABLED = "0";
        ldflags = [ "-s" "-w" ];
      };
      root = pkgs.runCommand "quicknotes-image-root" { } ''
        mkdir -p $out/bin
        cp ${quicknotes}/bin/quicknotes $out/bin/quicknotes
        cp ${./app/seed.json} $out/seed.json
      '';
      docker = pkgs.dockerTools.buildImage {
        name = "quicknotes-nix";
        tag = "0.1.0";
        copyToRoot = root;
        config = {
          Entrypoint = [ "/bin/quicknotes" ];
          User = "65532:65532";
          ExposedPorts = { "8080/tcp" = { }; };
          Env = [
            "ADDR=:8080"
            # /dev/shm is a writable runtime tmpfs for the non-root process.
            "DATA_PATH=/dev/shm/notes.json"
            "SEED_PATH=/seed.json"
          ];
        };
      };
    in
    {
      packages.${system} = {
        inherit quicknotes docker;
        default = quicknotes;
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ go gopls golangci-lint ];
      };
    };
}
