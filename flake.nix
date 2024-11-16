{
  description = "A very basic flake";

  inputs = {
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, arion }: {
    nixosModules.nix-docker-compose = ({ pkgs, lib, config, dockerPaths, ... }: {
      imports = [
        arion.nixosModules.arion
        ./module.nix
      ];
    });
    nixosModules.default = self.nixosModules.nix-docker-compose;
  };
}
