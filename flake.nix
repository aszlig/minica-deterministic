{
  description = "Deterministic version of a minimalist CA";

  inputs.nixpkgs.url = "nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs) lib;
  in {
    overlays.default = final: prev: {
      inherit (self.packages.${final.system}) minica-deterministic;
    };

    packages = lib.mapAttrs (system: pkgs: let
      patchedPkgs = pkgs.extend (lib.const (super: {
        buildGoModule = super.buildGoModule.override (attrs: {
          go = attrs.go.overrideAttrs (drv: {
            # Make MaybeReadByte a no-op, since this is used to *prevent*
            # determinism.
            postPatch = (drv.postPatch or "") + ''
              sed -i -n -e '
                /^import (/,/)/ { \!"math/rand/v2"!d }
                /^func MaybeReadByte.*{/ {
                  p; :l; n; /^}/!bl
                }; p
              ' src/crypto/internal/randutil/randutil.go
            '';
            # Some tests fail because the test certificates expired in 2025:
            # https://github.com/golang/go/issues/71077
            doCheck = false;
          });
        });
      }));

      minica-deterministic = patchedPkgs.minica.overrideAttrs (drv: {
        pname = "minica-deterministic";
        patches = (drv.patches or []) ++ [ patches/minica.patch ];
      });
      ca = patchedPkgs.runCommand "snakeoil-ca" {
        nativeBuildInputs = lib.singleton minica-deterministic;

        passthru.mkCert = { domain, extraDomains ? [], serial ? 100000 }: let
          domains = lib.singleton domain ++ extraDomains;
        in patchedPkgs.runCommand "snakoil-cert-${domain}" {
          inherit ca domain;
          domains = lib.concatStringsSep "," domains;
          nativeBuildInputs = assert serial >= 100000; [
            minica-deterministic
          ];
        } ''
          minica --ca-key "$ca/key.pem" --ca-cert "$ca/cert.pem" \
            --serial ${lib.escapeShellArg (toString serial)} \
            --domains "$domains"
          mv "$domain" "$out"
        '';
      } ''
        mkdir "$out"
        minica --ca-key "$out/key.pem" --ca-cert "$out/cert.pem" \
          --domains dummy.test
      '';
    in {
      default = self.packages.${system}.minica-deterministic;
      minica-deterministic = minica-deterministic // { inherit ca; };
    }) nixpkgs.legacyPackages;

    checks = lib.mapAttrs (system: pkgs: rec {
      build = self.packages.${system}.minica-deterministic;

      determinism = pkgs.runCommand "test-determinism" {
        nativeBuildInputs = [ pkgs.nix build ];
      } ''
        for testrun in $(seq 5); do
          mkdir "test$testrun"
          echo -n "Run $testrun" >&2
          ( cd "test$testrun"
            for domain in $(seq 10 | sed -e 's/.*/domain&.test/'); do
              minica --ca-key ca-key.pem --ca-cert ca-cert.pem \
                --domains "$domain"
            done
          )
          hash="$(nix-hash --base32 --type sha256 "test$testrun")"
          if [ -n "$oldhash" ] && [ "$hash" != "$oldhash" ]; then
            echo " FAILED: $hash != $oldhash" >&2
            exit 1
          else
            echo ": $hash" >&2
          fi
          test -n "$hash"
          oldhash="$hash"
        done
        touch "$out"
      '';

      overlay = let
        inherit (import nixpkgs {
          inherit system;
          overlays = lib.singleton self.overlays.default;
        }) minica-deterministic;
      in pkgs.runCommand "test-overlay" {
        inherit (minica-deterministic) ca;
        domain1 = minica-deterministic.ca.mkCert { domain = "domain1.test"; };
        domain2 = minica-deterministic.ca.mkCert {
          domain = "domain2.test";
          extraDomains = [ "domain3.test" "domain4.test" ];
        };
        nativeBuildInputs = lib.singleton pkgs.openssl;
      } ''
        openssl verify -verbose -CAfile "$ca/cert.pem" "$domain1/cert.pem"
        openssl verify -verbose -CAfile "$ca/cert.pem" "$domain2/cert.pem"
        touch "$out"
      '';
    }) nixpkgs.legacyPackages;
  };
}
