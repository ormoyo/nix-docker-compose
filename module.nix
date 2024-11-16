{ pkgs, config, lib, dockerPaths, ... }:
let
  inherit (lib)
    attrByPath
    attrsets
    concatMapAttrs
    filterAttrs
    flatten
    foldl'
    mergeAttrs
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    optional
    removeSuffix
    splitString
    types;

  cfg = config.services.docker;

  sepIfNo0 = sep: list: if (builtins.length list) > 0 then sep + (builtins.concatStringsSep sep list) else "";

  sortFiles = path: sortFiles' path [ ];
  sortFiles' = path: dirs: concatMapAttrs
    (name: type:
      if type != "directory" then { "${removeSuffix ".nix" name}${sepIfNo0 "$" dirs}" = path; }
      else (sortFiles' "${path}/${name}" (dirs ++ [ name ]))
    )
    (builtins.readDir path);

  dirFiles = foldl' mergeAttrs { } (builtins.map (dir: sortFiles dir) dockerPaths);
  removeSignIfNoDup = name:
    let
      n = builtins.elemAt (splitString "$" name) 0;
    in
    if dirFiles ? ${n} then name else n;

  step1 = filterAttrs (n: v: n != "default") dirFiles;
  step2 = attrsets.mapAttrs' (file: path: nameValuePair (removeSignIfNoDup file) path) step1;

  getUser = service: cfg.services.${service}.user;
  import_file = path: name:
    import "${path}/${name}.nix" {
      name = cfg.services.${name}.serviceName;
      id =
        if builtins.isString (getUser name)
        then config.users.users.${getUser name}.uid
        else (getUser name);
      cfg = cfg.services.${name};
      path = cfg.services.${name}.dataDir;
      getSecret = secret:
        if secret == "TZ"
        then config.sops.secrets."docker/TZ".path
        else config.sops.secrets."docker/${name}/${secret}".path;
      inherit pkgs;
      inherit config;
      inherit lib;
    };

  modules = builtins.mapAttrs (name: path: import_file path (builtins.elemAt (splitString "$" name) 0)) step2;
  create_option = name: module:
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
            default = false;
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
    };

  options = builtins.mapAttrs (name: module: create_option name module) modules;
in
{
  options.services.docker = {
    enable = mkEnableOption "Ormoyo's docker module";

    dataPath = mkOption {
      type = types.str;
      default = "/opt/docker";
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
      services = builtins.mapAttrs
        (name: module: {
          serviceName = name;
          settings = filterAttrs (n: v: n != "custom") module;
        })
        enabledModules;

      paths = flatten (builtins.attrValues
        (builtins.mapAttrs
          (n: v:
            [ (cfg.services.${n}.dataDir) ]
            ++ (builtins.attrValues cfg.services.${n}.extraPaths))
          enabledModules));

      exclusions = flatten (builtins.attrValues
        (builtins.mapAttrs
          (name: module:
            let
              isBackupEnabled = attrByPath [ "custom" "backups" "enable" ] true module;
              exclusions =
                (attrByPath [ "custom" "backups" "exclude" ] [ ] module)
                ++ optional (!isBackupEnabled) "**";
            in
            (cfg.services.${name}.backups.exclude ++ exclusions)
          )
          enabledModules));

      secrets = concatMapAttrs
        (name: module:
          builtins.listToAttrs (builtins.map
            (secret: nameValuePair "docker/${name}/${secret}" {
              owner = cfg.services.${name}.user;
              restartUnits = [ "${name}.service" ];
            })
            (attrByPath [ "custom" "secrets" ] [ ] module))
        )
        enabledModules;

      activations = concatMapAttrs
        (name: module:
          attrsets.mapAttrs'
            (n: value: nameValuePair "docker-${name}-${n}" value)
            (attrByPath [ "custom" "activationScripts" ] { } module))
        enabledModules;

      systemd = builtins.mapAttrs
        (name: module: mkIf (!cfg.services.${name}.autoStart) {
          after = lib.mkForce [ ];
        })
        enabledModules;
    in
    mkIf cfg.enable {
      #  users.extraUsers.ormoyo.extraGroups = [ "podman" ];
      services.backups = mkIf cfg.backups.enable {
        enable = true;
        repos.docker = {
          paths = paths;
          time = cfg.backups.time;
          timePersistent = cfg.backups.timePersistent;
          exclude = exclusions;
        };
      };

      sops.secrets = secrets // {
        "docker/TZ" = { mode = "0444"; };
      };

      system.activationScripts = activations;
      systemd.services = systemd;

      virtualisation = {
        docker.enable = true;
        arion = {
          backend = "docker";
          projects = services;
        };
      };
    };
}
