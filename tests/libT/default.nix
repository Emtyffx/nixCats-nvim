# Copyright (c) 2023 BirdeeHub 
# Licensed under the MIT license
{
  inputs
  , utils

  , pkgs
  , lib
  , stdenv
  , nix
  , writeText
  , writeShellScript
  , ...
}: with builtins; rec {
  pureCallFlakeOverride = path: inputs: let
    bareflake = import "${path}/flake.nix";
    res = bareflake.outputs (inputs // rec {
      self = res // {
        outputs = res;
        outPath = path;
        inputs = builtins.mapAttrs (n: _:
            (inputs // { inherit self; }).${n} or builtins.throw "Missing input ${n}"
          ) bareflake.inputs;
      };
    });
  in res;
  mkHMmodulePkgs = {
    package
    , entrymodule
    , stateVersion ? "24.05"
    , username ? "REPLACE_ME"
    , ...
  }: let
    packagename = package.nixCats_packageName;
    moduleNamespace = package.moduleNamespace;
    hmcfg = inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit
          packagename
          moduleNamespace
          username
          package
          inputs
          utils
          ;
      };
      modules = [
        entrymodule
        package.homeModule
        ({ ... }: {
          home.username = username;
          home.homeDirectory = lib.mkDefault (let
            homeDirPrefix = if stdenv.hostPlatform.isDarwin then "Users" else "home";
          in "/${homeDirPrefix}/${username}");
          programs.home-manager.enable = true;
          nix.package = nix;
          home.stateVersion = stateVersion;
        })
      ];
    };
  in lib.attrByPath ([ "config" ] ++ moduleNamespace ++ [ "out" ]) {} hmcfg;

  mkNixOSmodulePkgs = {
    package
    , entrymodule
    , ...
  }: let
    # NOTE: too hard to set all the system options
    # to make it work without building it on a system apparently
    # so we use lib.evalModules and make our own options to set
    # to mirror the ones the nixCats module uses.
    packagename = package.nixCats_packageName;
    moduleNamespace = package.moduleNamespace;
    nixoscfg = inputs.nixpkgs.lib.evalModules {
      modules = [
        entrymodule
        package.nixosModule
        ({ ... }:{
          options = {
            environment.systemPackages = lib.mkOption {
              default = [];
              type = lib.types.listOf lib.types.package;
            };
            users.users = lib.mkOption {
              default = {};
              type = lib.types.attrsOf (lib.types.submodule {
                options.packages = lib.mkOption {
                  default = [];
                  type = lib.types.listOf lib.types.package;
                };
              });
            };
          };
        })
      ];
      specialArgs = {
        inherit
          packagename
          moduleNamespace
          pkgs
          lib
          inputs
          package
          utils
          ;
      };
    };
  in lib.attrByPath ([ "config" ] ++ moduleNamespace ++ [ "out" ]) {} nixoscfg;

  mkRunPkgTest = {
    package,
    packagename ? package.nixCats_packageName,
    runnable_name ? packagename,
    runnable_is_nvim ? true,
    preRunBash ? "",
    testnames ? {},
    ...
  }: let
    finaltestvim = package.override (prev: {
      categoryDefinitions = utils.deepmergeCats prev.categoryDefinitions ({ pkgs, categories, settings, name, ... }:{
        extraLuaPackages = {
          nixCats_test_lib_deps = (lp: with lp; [
            lze
            ansicolors
            luassert
          ]);
        };
      });
      packageDefinitions = prev.packageDefinitions // {
        ${packagename} = utils.mergeCatDefs prev.packageDefinitions.${packagename} ({ pkgs, ... }: {
          categories = {
            nixCats_test_lib_deps = true;
            killAfter = true;
            nixCats_test_names = testnames;
          };
        });
      };
    });
    # defined separately just to absolutely guarantee the testing library is always run FIRST.
    # although using optionalLuaPreInit in categoryDefinitions would most likely be sufficient.
    luaPre = writeText "luaPreCfg" /*lua*/''
      package.preload.libT = function()
        return dofile([[${./libT.lua}]])
      end
      require('libT')
    '';
    runtests = nightly: fvim: /*bash*/''
      HOME="$(mktemp -d)"
      TEST_TEMP="$(mktemp -d)"
      mkdir -p "$TEST_TEMP" "$HOME"
      cd "$TEST_TEMP"
      [ ! -f "${fvim}/bin/${runnable_name}" ] && \
        echo "${fvim}/bin/${runnable_name} does not exist!" && exit 1
      ${preRunBash}
    '' + (if runnable_is_nvim then ''
      "${fvim}/bin/${runnable_name}" --headless \
        --cmd "lua vim.g.nix_test_out = [[$out]]; vim.g.nix_test_src = [[$src]]; vim.g.nix_test_temp = [[$TEST_TEMP]]; dofile('${luaPre}')" "$@"
    '' else ''
      ${fvim}/bin/${runnable_name} "$@"
    '');
  in writeShellScript "runtests-${packagename}-${runnable_name}" ''
    unset IS_NIGHTLY_NVIM
    ${runtests false finaltestvim}
  '' + (if runnable_is_nvim then "\n
    export IS_NIGHTLY_NVIM=true
    ${runtests true (finaltestvim.overrideNixCats (prev: { dependencyOverlays = prev.dependencyOverlays or [] ++ [ inputs.neovim-nightly-overlay.overlays.default ]; }))}
  " else "");
}
