{
  description = "hearsay — push-to-talk dictation; hearsay-rs for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs:
        let
          inherit (pkgs) lib stdenv;
          # Loaded with dlopen at run time by winit, glutin, global-hotkey: they must be on the
          # library path, not only at link time.
          runtimeLibs = lib.optionals stdenv.isLinux (with pkgs; [
            libGL
            libxkbcommon
            wayland
            xorg.libX11
            xorg.libXcursor
            xorg.libXi
            xorg.libXrandr
            xorg.libXext
            xorg.libXtst
            xorg.libXinerama
            xorg.libxcb
          ]);
          hearsay-rs = pkgs.rustPlatform.buildRustPackage {
            pname = "hearsay-rs";
            version = "0.2.1";
            src = ./crossplatform;
            cargoLock.lockFile = ./crossplatform/Cargo.lock;
            cargoBuildFlags = [ "-p" "hearsay-rs" ];
            cargoTestFlags = [ "--workspace" ];

            nativeBuildInputs = with pkgs; [
              pkg-config
              cmake # whisper.cpp
              rustPlatform.bindgenHook # whisper-rs-sys bindings need libclang
              makeWrapper
            ];
            buildInputs = lib.optionals stdenv.isLinux (with pkgs; [
              alsa-lib # microphone (cpal)
              xdotool # libxdo: the paste keystroke (enigo)
              xorg.libX11
              xorg.libXext
              xorg.libXtst
              xorg.libXinerama
              xorg.libXi
              libxkbcommon
              wayland
            ]); # macOS: the frameworks come with the darwin stdenv

            # whisper.cpp's cmake is driven by the whisper-rs-sys build script, not by nix.
            dontUseCmakeConfigure = true;
            # No -march=native inside the sandbox: a portable ggml (nix gcc also rejects ggml's arm64 flags).
            CMAKE_TOOLCHAIN_FILE = ./crossplatform/cmake/portable.cmake;

            postInstall = lib.optionalString stdenv.isLinux ''
              wrapProgram $out/bin/hearsay-rs \
                --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs}
            '';

            meta = with lib; {
              description = "Push-to-talk dictation with on-device whisper.cpp, a bake-off lab, and optional cloud engines";
              homepage = "https://github.com/note89/hearsay";
              license = licenses.gpl3Only;
              mainProgram = "hearsay-rs";
              platforms = platforms.linux ++ platforms.darwin;
            };
          };
        in
        {
          inherit hearsay-rs;
          default = hearsay-rs;
        });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.system}.hearsay-rs ];
          packages = with pkgs; [ cargo rustc rust-analyzer clippy rustfmt ];
          LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.isLinux (pkgs.lib.makeLibraryPath (with pkgs; [
            libGL libxkbcommon wayland xorg.libX11 xorg.libXcursor xorg.libXi xorg.libXrandr
          ]));
        };
      });
    };
}
