{
  description = "Deterministic version of a minimalist CA";

  inputs.nixpkgs.url = "nixpkgs/nixos-20.09";

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs) lib;
  in {
    overlay = final: prev: {
      minica-deterministic = let
        inherit (self.packages.${final.system}) minica-deterministic;
      in minica-deterministic // {
        ca = final.runCommand "snakeoil-ca" {
          nativeBuildInputs = lib.singleton minica-deterministic;

          passthru.mkCert = { domain, extraDomains ? [] }: let
            domains = lib.singleton domain ++ extraDomains;
          in final.runCommand "snakoil-cert-${domain}" {
            inherit (final.minica-deterministic) ca;
            inherit domain;
            domains = lib.concatStringsSep "," domains;
            nativeBuildInputs = lib.singleton minica-deterministic;
          } ''
            minica --ca-key "$ca/key.pem" --ca-cert "$ca/cert.pem" \
              --domains "$domains"
            mv "$domain" "$out"
          '';
        } ''
          mkdir "$out"
          minica --ca-key "$out/key.pem" --ca-cert "$out/cert.pem" \
            --domains dummy.test
        '';
      };
    };

    packages = lib.mapAttrs (system: pkgs: {
      minica-deterministic = let
        patchedPkgs = pkgs.extend (lib.const (super: {
          buildGoPackage = super.buildGoPackage.override (attrs: {
            go = attrs.go.overrideAttrs (drv: {
              # Make MaybeReadByte a no-op, since this is used to *prevent*
              # determinism.
              postPatch = (drv.postPatch or "") + ''
                sed -i -n -e '/^func MaybeReadByte.*{/ {
                  p; :l; n; /^}/!bl
                }; p' src/crypto/internal/randutil/randutil.go
              '';
            });
          });
        }));
      in patchedPkgs.minica.overrideAttrs (drv: {
        pname = "minica-deterministic";
        postPatch = (drv.postPatch or "") + ''
          sed -i -e '
            /import.*(/,/)/ { s!"crypto/rand"!"math/rand"!g; s/"math"// }
            /rand.Int(/ {
              :l; N; /}/!bl
              c var serial = big.NewInt(123456789)
              b
            }
            s/rand\.Reader/rand.New(rand.NewSource(123456789))/g
            s/time\.Now()/time.Unix(1602785939, 0)/g
            s/AddDate([^)]*)/AddDate(1000, 0, 0)/g
          ' main.go
        '';
      });
    }) nixpkgs.legacyPackages;

    defaultPackage = lib.mapAttrs (_: p: p.minica-deterministic) self.packages;

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
          overlays = lib.singleton self.overlay;
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
