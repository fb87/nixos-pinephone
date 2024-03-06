# vim: tabstop=2 expandtab autoindent
{
  description = "NixOS for Pinephone";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-23.11-small";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      pkgs-cross = import nixpkgs {
        crossSystem = {
          config = "aarch64-unknown-linux-gnu";
        };

        system = "x86_64-linux";
      };

      atf = pkgs-cross.stdenv.mkDerivation rec {
        pname = "a64-atf";
        version = "unstable";

        src = pkgs-cross.fetchFromGitHub {
          owner = "crust-firmware";
          repo = "arm-trusted-firmware";
          rev = "5746d275f1bc370c7e1f18727c602bd953984865";
          sha256 = "sha256-TYKA6TBZvr3WMhi0yVvOm4qIYchvsdnobxY1vuIE3Gw=";
        };

        configurePhase = ''
          patchShebangs tools

          # remove the warning regarding to RWX segment,
          # not forming the patch cuz it not that worth yet.
          echo "TF_LDFLAGS    +=  --no-warn-rwx-segment" >> Makefile
        '';

        buildPhase = ''
          export CROSS_COMPILE=aarch64-unknown-linux-gnu-
          export ARCH=arm64
          make PLAT=sun50i_a64 -j$(nproc) bl31
        '';

        installPhase = ''
          mkdir $out
          cp build/sun50i_a64/release/bl31.bin $out
        '';
      };

      or1k-toolchains = pkgs.runCommandNoCC ""
        {
          src = pkgs.fetchurl {
            url = "https://musl.cc/or1k-linux-musl-cross.tgz";
            sha256 = "sha256-SXUYVvR7P27kaOqGestr9IKxtK/1clfeSC6NHJ8425Q=";
          };

          buildInputs = with pkgs; [ autoPatchelfHook ];
        } ''
        mkdir $out
        tar xf $src --strip-component 1 -C $out
      '';

      crust = pkgs-cross.stdenv.mkDerivation rec {
        pname = "pinephone-crust";
        version = "unstable";

        src = pkgs.fetchFromGitHub {
          owner = "crust-firmware";
          repo = "crust";
          rev = "v0.6";
          sha256 = "sha256-zalBVP9rI81XshcurxmvoCwkdlX3gMw5xuTVLOIymK4=";
        };

        nativeBuildInputs = with pkgs; [ gcc pkg-config flex bison ] ++ [ or1k-toolchains ];

        configurePhase = ''
          patchShebangs tools scripts
          make pinephone_defconfig CROSS_COMPILE=${or1k-toolchains}/bin/or1k-linux-musl-
        '';

        buildPhase = ''
          make -j$(nproc) scp CROSS_COMPILE=${or1k-toolchains}/bin/or1k-linux-musl-
        '';

        installPhase = ''
          mkdir $out
          cp build/scp/scp.bin $out
        '';
      };

      u-boot = pkgs-cross.stdenv.mkDerivation rec {
        pname = "u-boot";
        version = "v2023.07.02";

        src = pkgs.fetchFromGitHub {
          owner = "u-boot";
          repo = "u-boot";
          rev = "${version}";
          sha256 = "sha256-HPBjm/rIkfTCyAKCFvCqoK7oNN9e9rV9l32qLmI/qz4=";
        };

        buildInputs = with pkgs; [
          openssl
        ];

        nativeBuildInputs = with pkgs; [
          (python3.withPackages (p: with p; [
            setuptools
            pyelftools
          ]))

          gcc
          swig
          bison
          flex
          bc
        ];

        configurePhase = ''
          patchShebangs tools scripts
        '';

        buildPhase = ''
          export CROSS_COMPILE=aarch64-unknown-linux-gnu-
          export ARCH=arm64

          export BL31=${atf}/bl31.bin
          export SCP=${crust}/scp.bin
          make distclean
          make pinephone_defconfig
          make all -j$(nproc)
        '';

        installPhase = ''
          mkdir $out
          cp *.bin $out

          echo "Flashing: sudo dd if=$out/u-boot-sunxi-with-spl.bin of=/dev/[CHANGE THIS] bs=1024 seek=8" > $out/README.md
        '';
      };

      flake-files = pkgs.stdenvNoCC.mkDerivation {
        pname = "flake-files";
        version = "unstable";

        src = ./.;

        installPhase = ''
          tar czf $out *
        '';
      };
    in
    rec
    {
      nixosConfigurations.live = nixpkgs.lib.nixosSystem {
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64-installer.nix"

          {
            nixpkgs.config.allowUnsupportedSystem = true;
            nixpkgs.hostPlatform.system = "aarch64-linux";
            nixpkgs.buildPlatform.system = "x86_64-linux";
          }

          ({ ... }: {

            hardware = {
              deviceTree = { name = "allwinner/sun50i-a64-pinephone-1.1.dtb"; };
              opengl.enable = true;
            };

            sdImage = {
              # 16MiB should be enough (u-boot-rockchip.bin ~ 10MiB)
              firmwarePartitionOffset = 16;
              firmwarePartitionName = "Firmwares";

              compressImage = true;
              expandOnBoot = true;

              # u-boot-rockchip.bin is all-in-one bootloader blob, flashing to the image should be enough
              populateFirmwareCommands = "dd if=${u-boot}/u-boot-sunxi-with-spl.bin of=$img seek=8 bs=1024 conv=notrunc";

              # make sure u-boot available on the firmware partition, cuz we do need this
              # to write to eMMC
              postBuildCommands = ''
                cp ${u-boot}/u-boot-sunxi-with-spl.bin ${flake-files} firmware/
              '';
            };

            system.stateVersion = "23.11";
          })
        ];
      };

      formatter.x86_64-linux = pkgs.nixpkgs-fmt;
      packages.x86_64-linux.default = nixosConfigurations.live.config.system.build.sdImage;

    };
}
