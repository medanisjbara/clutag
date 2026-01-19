{ pkgs ? import <nixpkgs> {} }:

pkgs.lua54Packages.buildLuaPackage {
  pname = "clutag";
  version = "0.1.0";

  src = ./.;

  dontBuild = true;

  propagatedBuildInputs = [
    pkgs.lua54Packages.luafilesystem
    pkgs.lua54Packages.lua-cjson
  ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp clutag.lua $out/bin/clutag
    chmod +x $out/bin/clutag
  '';

  postFixup = ''
    wrapProgram $out/bin/clutag \
      --prefix LUA_PATH ";" "$LUA_PATH" \
      --prefix LUA_CPATH ";" "$LUA_CPATH"
  '';
}
