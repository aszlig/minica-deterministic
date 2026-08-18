{
  description = "Deterministic version of a minimalist CA";

  inputs.nixpkgs.url = "nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs) lib;
  in {
    overlays.default = final: prev: {
      inherit (self.packages.${final.system})
        minica-deterministic pebble-deterministic;
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
      pebble-deterministic = patchedPkgs.pebble.overrideAttrs (drv: {
        patches = (drv.patches or []) ++ [ patches/pebble.patch ];
      });
    }) nixpkgs.legacyPackages;

    nixosModules.pebble-deterministic = { config, pkgs, ... }: let
      cfg = config.test-support.pebble-deterministic;
      inherit (self.packages.${pkgs.system})
        minica-deterministic pebble-deterministic;
    in {
      options.test-support.pebble-deterministic = {
        caCert = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          default = "${minica-deterministic.ca}/cert.pem";
          description = ''
            A certificate file to use with the `nodes` attribute to inject the
            test CA certificate used in the ACME server into
            {option}`security.pki.certificateFiles`.
          '';
        };
        caDomain = lib.mkOption {
          type = lib.types.str;
          default = "acme-v02.api.letsencrypt.org";
          description = ''
            A domain name to use with the `nodes` attribute to identify the CA
            server.
          '';
        };
      };

      config.networking.firewall.enable = false;
      config.systemd.services.pebble-deterministic = {
        description = "Deterministic Pebble ACME server";
        after = [ "network.target" ];
        requiredBy = [ "multi-user.target" ];

        environment = {
          PEBBLE_VA_NOSLEEP = "1";
          PEBBLE_WFE_NONCEREJECT = "0";
        };

        serviceConfig = {
          RuntimeDirectory = "pebble-deterministic";
          WorkingDirectory = "/run/pebble-deterministic";
          ExecStart = let
            wfeCert = minica-deterministic.ca.mkCert {
              domain = cfg.caDomain;
            };
            configFile = pkgs.writers.writeJSON "pebble-deterministic.conf" {
              pebble = {
                listenAddress = "[::]:443";
                managementListenAddress = "[::]:15000";
                certificate = "${wfeCert}/cert.pem";
                privateKey = "${wfeCert}/key.pem";
                httpPort = 80;
                tlsPort = 443;
                ocspResponderURL = "http://${cfg.caDomain}:4002";
                strict = true;
              };
            };
          in "${pebble-deterministic}/bin/pebble -config ${configFile}";
        };
      };
    };

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

      pebble = pkgs.testers.runNixOSTest {
        name = "pebble-deterministic";

        defaults = { nodes, ... }: {
          networking.firewall.enable = false;
          networking.nameservers = [
            nodes.dns.networking.primaryIPAddress
            nodes.dns.networking.primaryIPv6Address
          ];
          security.pki.certificateFiles = [
            nodes.acme.test-support.pebble-deterministic.caCert
          ];
        };

        nodes = {
          acme.imports = [ self.nixosModules.pebble-deterministic ];
          client = {};
          dns = { lib, nodes, config, ... }: {
            services.bind.enable = true;
            services.bind.cacheNetworks = lib.mkForce [ "any" ];
            services.bind.forwarders = lib.mkForce [];
            services.bind.extraOptions = "empty-zones-enable no;";
            services.bind.zones = let
              extractA = fqdn: nodecfg: ''
                ${fqdn}. IN A ${nodecfg.networking.primaryIPAddress}
                ${fqdn}. IN AAAA ${nodecfg.networking.primaryIPv6Address}
              '';

              inherit (nodes.acme.test-support.pebble-deterministic) caDomain;

              extractAsFromNode = node: let
                inherit (node.services.nginx) virtualHosts;
                extractFromVhost = fqdn: lib.const (extractA fqdn node);
              in lib.mapAttrsToList extractFromVhost virtualHosts;
              hasNginxEnabled = node: node.services.nginx.enable;
              nginxNodes = lib.filterAttrs (lib.const hasNginxEnabled) nodes;
              nginxNodeConfigs = lib.attrValues nginxNodes;
              nginxARecords = lib.concatMap extractAsFromNode nginxNodeConfigs;

            in lib.singleton {
              name = ".";
              master = true;
              file = pkgs.writeText "root.zone" ''
                $TTL 3600
                . IN SOA ns.fakedns. admin.fakedns. ( 1 3h 1h 1w 1d )
                . IN NS ns.fakedns.
                ${extractA "ns.fakedns" config}
                ${extractA caDomain nodes.acme}
                ${lib.concatStrings nginxARecords}
              '';
            };
          };
        } // lib.mapAttrs (serverName: fqdn: {
          security.acme.acceptTerms = true;
          security.acme.defaults.email = "ssladmin@${fqdn}";
          services.nginx.enable = true;
          services.nginx.virtualHosts.${fqdn} = {
            enableACME = true;
            forceSSL = true;
            locations."/".root = pkgs.writeTextDir "index.txt" ''
              Hello from ${serverName}!
            '';
          };
        }) {
          server1 = "example.com";
          server2 = "example.net";
          server3 = "example.org";
        };

        testScript = ''
          import shlex

          def wait_until_cert_issued(node: BaseMachine, domain: str) -> None:
            node.wait_for_unit('nginx.service')
            unit = f'acme-order-renew-{domain}.service'
            node.succeed(f'systemctl start {shlex.quote(unit)}')

          acme.start()
          dns.wait_for_unit('bind.service')
          acme.wait_for_unit('multi-user.target')

          start_all()
          wait_until_cert_issued(server1, 'example.com')
          wait_until_cert_issued(server2, 'example.net')
          wait_until_cert_issued(server3, 'example.org')

          result = client.succeed('curl -f https://example.com/index.txt')
          t.assertEqual(result, 'Hello from server1!\n')
          result = client.succeed('curl -f https://example.net/index.txt')
          t.assertEqual(result, 'Hello from server2!\n')
          result = client.succeed('curl -f https://example.org/index.txt')
          t.assertEqual(result, 'Hello from server3!\n')
        '';
      };
    }) nixpkgs.legacyPackages;
  };
}
