{ pkgs, config, lib, containerPaths, ... }:
let
  inherit (builtins)
    attrValues
    concatLists
    concatStringsSep
    elemAt
    isString
    length
    listToAttrs
    map
    mapAttrs;
  inherit (lib)
    attrByPath
    concatMapAttrs
    filterAttrs
    foldl'
    mapAttrs'
    mergeAttrs
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    optional
    removeSuffix
    splitString
    types;

  cfg = config.services.containers;

  separateDirs = sep: dirs: 
    if (length list) > 0 
    then sep + (concatStringsSep sep dirs) 
    else "";

  sortFiles = path: sortFiles' path [ ];
  sortFiles' = path: dirs: concatMapAttrs
    (name: type:
      if type != "directory" then { "${removeSuffix ".nix" name}${separateDirs "$" dirs}" = path; }
      else (sortFiles' "${path}/${name}" (dirs ++ [ name ]))
    )
    (builtins.readDir path);

  modules = containerPaths
    |> map (path: sortFiles path)
    |> foldl' (mergeAttrs) { }
    |> filterAttrs (n: v: n != "default")
    |> (modules: 
      mapAttrs' (file: path:
        let 
          service = cfg.services.${name};
          name = elemAt (splitString "$" file) 0;
          uniqueName =
            if modules ? ${name} 
            then file
            else name;
        in nameValuePair uniqueName
          <| import "${path}/${name}.nix" { 
            name = service.serviceName;
            id =
              if isString service.user
              then config.users.users.${service.user}.uid
              else service.user;
            path = service.dataDir;
            getSecret = secret:
              if secret == "TZ"
              then config.sops.secrets."containers/TZ".path
              else config.sops.secrets."containers/${uniqueName}/${secret}".path;
            inherit pkgs config cfg lib;
          }
      ) modules);

  options = modules |>
    mapAttrs
    (name: module:
      mkOption {
        default = { };
        type = types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
            };

            autoStart = mkOption {
              type = types.bool;
              default = true;
            };

            serviceName = mkOption {
              type = types.str;
              default = name;
            };

            dataDir = mkOption {
              type = types.str;
              default = "${cfg.dataPath}/${name}";
            };

            backups.exclude = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };

            user = mkOption {
              type = with types; either str ints.unsigned;
              default = cfg.user;
            };

            extraPaths = mkOption {
              type = types.attrsOf types.str;
              default = { };
            };
          } //
          (attrByPath [ "custom" "options" ] { } module);
        };
      });
in
{
  options.services.containers = {
    enable = mkEnableOption "Ormoyo's docker compose module";

    backend = mkOption {
      type = types.enum [ "docker" "podman" ];
      default = "podman";
    };

    dataPath = mkOption {
      type = types.str;
      default = "/opt/containers";
    };

    user = mkOption {
      type = with types; either str ints.unsigned;
      default = 1000;
    };

    backups = mkOption {
      default = { };
      type = types.submodule {
        options = {
          enable = mkEnableOption "backing up docker dirs";
          time = mkOption {
            type = types.str;
          };
          timePersistent = mkOption {
            type = types.bool;
            default = true;
          };
        };
      };
    };

    services = mkOption {
      default = { };

      description = "Contains all specific docker service options";
      example = {
        nginx.enable = false;
        nginx.user = 0;
        nginx.dataDir = "/var/nginx";
      };

      type = types.submodule {
        options = options;
      };
    };
  };

  config =
    let
      enabledModules = filterAttrs (name: value: cfg.services.${name}.enable) modules;
      services = mapAttrs
        (name: module: {
          serviceName = name;
          settings = filterAttrs (n: v: n != "custom") module;
        })
        enabledModules;

      paths = enabledModules
        |> mapAttrs 
            (n: v: [ (cfg.services.${n}.dataDir) ] 
            ++ (attrValues cfg.services.${n}.extraPaths))
        |> attrValues
        |> concatLists;

      exclusions = enabledModules
        |> mapAttrs
            (name: module:
            let
              enabled = attrByPath [ "custom" "backups" "enable" ] true module;
              exclusions = 
                (attrByPath [ "custom" "backups" "exclude" ] [ ] module)
                ++ optional (!enabled) "**";
            in 
            (cfg.services.${name}.backups.exclude ++ exclusions))
        |> attrValues
        |> concatLists;

      secrets = enabledModules
        |> mapAttrs (name: mod: 
          attrByPath [ "custom" "secrets" ] [ ] mod 
            |> map (secret:
              nameValuePair "containers/${name}/${secret}" {
                owner = cfg.services.${name}.user;
                restartUnits= [ "${name}.service" ];
              }
            )
          )
        |> attrValues
        |> concatLists
        |> listToAttrs;

      activations = concatMapAttrs
        (name: module:
          mapAttrs'
            (n: value: nameValuePair "containers-${name}-${n}" value)
            (attrByPath [ "custom" "activationScripts" ] { } module))
        enabledModules;

      systemd = mapAttrs
        (name: module: mkIf (!cfg.services.${name}.autoStart) {
          after = lib.mkForce [ ];
        })
        enabledModules;
    in
    mkIf cfg.enable {
      #  users.extraUsers.ormoyo.extraGroups = [ "podman" ];
      services.backups = mkIf cfg.backups.enable {
        enable = true;
        repos.containers = {
          paths = paths;
          time = cfg.backups.time;
          timePersistent = cfg.backups.timePersistent;
          exclude = exclusions;
        };
      };

      sops.secrets = secrets // {
        "containers/TZ" = { mode = "0444"; };
      };

      system.activationScripts = activations;
      systemd.services = systemd;

      virtualisation = {
        ${cfg.backend}.enable = true;
        arion = {
          backend = if cfg.backend == "podman" then "podman-socket" else cfg.backend;
          projects = services;
        };
      };
    };
}
