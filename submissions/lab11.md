# Lab 11 — Reproducible QuickNotes builds with Nix

## Build recipe and environment

The root [flake.nix](../flake.nix) and [flake.lock](../flake.lock) pin `nixos-25.11` to nixpkgs commit `b6018f87da91d19d0ab4cf979885689b469cdd41`. That snapshot provided Go 1.25.10 for the application's `go 1.24` requirement. The recipe exposes `.#quicknotes`, `.#default`, `.#docker`, and a `devShell` with Go, gopls, and golangci-lint. Builds were run with Nix 2.31.2 in Linux containers; the independent local run used a fresh Git clone and a separate Nix store. CI used two fresh Ubuntu 24.04 runners.

The complete recipe is:

```nix
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
```

The image uses `/dev/shm` for its runtime notes file because the Nix-built root filesystem is read-only to the non-root UID. This is an ephemeral test image, not a persistent-notes deployment; production would mount a writable volume. The process itself runs as UID/GID `65532:65532`.

## Task 1 — reproducible Go binary

The first attempt used a placeholder `vendorHash`, as the lab suggests. Nix explicitly rejected it with `go: no dependencies to vendor` and `vendor folder is empty, please set 'vendorHash = null;' in your expression`. `app/go.mod` has no external modules, so there is no vendor tree whose hash can be pinned; `null` is the required, documented exception. The application source and Go toolchain remain fixed by the Git commit and lockfile. If external modules are added, the recipe must be changed to a real fixed-output `vendorHash`.

```text
$ nix build .#quicknotes
/nix/store/1ljpx7aw07wwzkaf6ym7abdkjannc59b-quicknotes-0.1.0
$ nix-store --query --hash /nix/store/1ljpx7aw07wwzkaf6ym7abdkjannc59b-quicknotes-0.1.0
sha256:1hv80kblj0zqcz82z0wihvxz63kylgwkqqgv5naykf0ar4f26w8k

Independent first local store, from the Windows-mounted worktree:
$ nix-store --query --hash /nix/store/xa29mlwgxna43kqhlibifzwy2wgpzy1r-quicknotes-0.1.0
sha256:1hv80kblj0zqcz82z0wihvxz63kylgwkqqgv5naykf0ar4f26w8k
```

The two store *paths* differ because Nix tracked differences in source-path metadata, but the queried NAR content hashes are identical. The [final green CI run](https://github.com/4rni4ka/DevOps-Intro/actions/runs/38787805229) independently confirms the same binary content hash on both fresh runners:

```text
Binary A: sha256:1hv80kblj0zqcz82z0wihvxz63kylgwkqqgv5naykf0ar4f26w8k
Binary B: sha256:1hv80kblj0zqcz82z0wihvxz63kylgwkqqgv5naykf0ar4f26w8k
```

The binary was executed with `SEED_PATH` pointed at the tracked `app/seed.json` and `DATA_PATH` at a writable temporary file. `curl -i http://127.0.0.1:28082/health` returned `HTTP/1.1 200 OK` and `{"notes":4,"status":"ok"}`.

### Design answers a–d

a) Go can produce identical binaries when the compiler, flags, environment, source bytes, and dependencies are all identical. A plain `go build` invocation alone does not pin those inputs: a different Go toolchain, module resolution, VCS/build metadata, source paths, or CGO toolchain can change the result. This flake pins the build environment and disables CGO; Lab 6's Docker *image* also has layer metadata outside the Go binary.

b) For a dependency-bearing module, `vendorHash` verifies the content of the vendored Go dependency tree produced for `buildGoModule`. Here that tree is empty, and Nix requires `null`, not a fabricated hash. Setting `null` after adding external dependencies would lose the fixed-output dependency guarantee and should be treated as a build/review failure requiring a real hash.

c) `flake.lock` records the exact nixpkgs revision and its content hash. Without it, resolving the channel again can select newer Go, libraries, or build helpers even when `flake.nix` is unchanged, so the second machine may build from different inputs.

d) `buildGoModule` is the standard nixpkgs builder using Go modules and a fixed vendor hash. `buildGoApplication` is commonly used with the separate gomod2nix approach, which generates and tracks module metadata differently. For this small standard Go-module project, `buildGoModule` requires fewer extra files and is sufficient.

## Task 2 — deterministic container image

`nix build .#docker` produced a tarball that `docker load` accepted as `quicknotes-nix:0.1.0`. Running that image returned HTTP 200 from `/health` with four seeded notes, and `docker image inspect` reported `User=65532:65532`. The image was built by Nix without a Docker daemon; Docker was used only to load and test the finished artifact.

The fresh Linux clone's tarball and the two independent CI jobs had the same byte-level SHA-256:

```text
Linux clone, separate Nix store:
$ sha256sum result
21364d82ef0fb520a774da7b147e03611b0eaf8eea6d14ab6276db1527782498  result

CI runner A: 21364d82ef0fb520a774da7b147e03611b0eaf8eea6d14ab6276db1527782498
CI runner B: 21364d82ef0fb520a774da7b147e03611b0eaf8eea6d14ab6276db1527782498
```

The Windows-mounted checkout's image tarball differed because its Git worktree/source-path metadata was not identical to the Linux clone, even though its binary NAR content hash matched. The image comparison above deliberately uses normalized Linux Git checkouts of the same commit. [.gitattributes](../.gitattributes) fixes line endings for the tracked app inputs; file-mode/checkout metadata must also be kept consistent when comparing cross-platform Nix image archives.

The Nix-loaded image appeared as 21.6 MB in `docker image ls`, versus 15.7 MB for the Lab 6 distroless image. Nix did not win this size comparison on this recipe; the runtime closure and image layout account for the difference.

Two fresh Lab 6 Docker builds using `docker build --no-cache` from the same Dockerfile produced different image IDs:

```text
qn-lab6:run1  sha256:90a69817723491990b57949d00ad732c901a8eb8f613534fa57a6bba772972c3  15.7MB
qn-lab6:run2  sha256:34776420171e8a6e5ae2571d24e08bc6669742f2514b96357d54a1aa51ebcb25  15.7MB
```

### Design answers e–g

e) Docker builds can record creation times in image/layer metadata and resolve mutable base-image tags or live package mirrors. Even with the same Dockerfile and source commit, those inputs can vary. The two no-cache builds above differed. Nix fixes the dependency graph through the lockfile and constructs this archive with normalized metadata.

f) A signature says a particular key endorsed a particular artifact; it does not prove that artifact corresponds to reviewed source. An auditor can independently rebuild this image from the pinned source/recipe and compare its exact SHA-256 to the distributed artifact, exposing a hidden build-stage modification that a signature alone would not reveal.

g) Nix brings an additional language, large initial cache, platform/checkout constraints, and more involved debugging. Dockerfiles are familiar and integrate readily with existing CI and registries. Reproducibility is valuable here, but it requires operational discipline beyond writing one flake.

## Bonus — CI gate and deliberate failure

The [nix-repro.yml workflow](../.github/workflows/nix-repro.yml) runs on every push and PR. It pins `actions/checkout` and `cachix/install-nix-action` to 40-character commit SHAs, starts two independent Ubuntu runners in parallel, builds `.#docker` and `.#quicknotes` in each, exports their hashes, and fails a third job if either pair differs.

The [initial green run](https://github.com/4rni4ka/DevOps-Intro/actions/runs/38786886518) showed matching image digests. For a controlled negative test, I temporarily added a step that appended whitespace to `app/seed.json` **only in job A's checkout**. No changed seed file was committed or deployed. The [red run](https://github.com/4rni4ka/DevOps-Intro/actions/runs/38787264336) showed:

```text
Build A: 38b8631e5681f0f6e0f2eb1f88c6ba7b95295c1ca1907cfa8ee858b3ad405f83
Build B: 21364d82ef0fb520a774da7b147e03611b0eaf8eea6d14ab6276db1527782498
Process completed with exit code 1.
```

The temporary step was removed. The [final green run](https://github.com/4rni4ka/DevOps-Intro/actions/runs/38787805229) has both image digests equal to `21364d82…` and both binary hashes equal to `sha256:1hv80kbl…`. The red test proves the comparison job detects a divergent build input; it does not claim Nix became nondeterministic for identical inputs.

### Design answers h–j

h) A laptop-only result can be contaminated by one machine's cache, custom configuration, or undeclared tools. Two separate CI runners supply independently provisioned environments and a public, repeatable verification record for an auditor.

i) Building twice in one job can reuse the same Nix store, compiler artifacts, environment variables, and machine-specific state. Parallel jobs start with separate runners/stores, so equality is stronger evidence of independent reproduction.

j) Timestamps can leak through generated files, compiler/linker metadata, or image creation/layer headers. `dockerTools.buildImage` normalizes its creation metadata by default; Nix's pure derivation does not automatically inherit an arbitrary `SOURCE_DATE_EPOCH` set only in a caller's shell. For the negative CI demonstration I therefore changed a tracked input in one job, rather than claiming an external timestamp variable changed this closed build.
