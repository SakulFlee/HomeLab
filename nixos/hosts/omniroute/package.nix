# OmniRoute (diegosouzapw/OmniRoute), packaged from the npm release.
#
# The shape here is "npm tarball's own production build + the git tree's lock":
#
#   * fetchFromGitHub gives the full v3.8.51 tree -- package-lock.json and the
#     workspaces (open-sse/, packages/browser-pool) exist only there, so this is
#     what `npm ci` runs against.
#   * fetchurl gives the published npm tarball, whose only reason to exist in
#     this expression is its prebuilt dist/ -- upstream's own Next.js
#     production build (~23k files). Copying it over the git tree's dist/ is
#     what lets dontNpmBuild below skip the Next build entirely, which is most
#     of the difference between a cheap image rebuild and an expensive one.
#
# Why not build dist from source: build-next-isolated.mjs is a full Next.js
# production build (webpack), minutes of wall clock and several GiB of heap,
# re-run on every image rebuild. The published dist IS that build, produced by
# upstream's CI for the same version the lock pins, so rebuilding it here buys
# nothing but reproducibility of a binary artefact that is already
# version-locked in the store by both hashes.
#
# Node version: engines allows ">=22.22.2 <23 || >=24 <27". nodejs_24 rather
# than nodejs (26?) so the instance does not change Node major under a nixpkgs
# bump -- the same reasoning hosts/renovate/default.nix gives.
#
# Natives, and what happens to each one:
#
#   sharp               regular dependency, ships prebuilt @img/* platform
#                       packages from the registry -- fetched by npmDeps like
#                       any other package, no compilation.
#   better-sqlite3      optional. prebuild-install cannot reach GitHub releases
#                       in the sandbox and falls through to node-gyp, which
#                       compiles offline against npm_config_nodedir (the headers
#                       the nodejs package ships). If even that fails, npm drops
#                       the optional dep and OmniRoute falls back to sql.js
#                       (a regular dependency, WASM).
#   wreq-js, keytar,
#   onnxruntime-node    optional. Same story; a failure skips the dep and the
#                       features that need it degrade (undici covers HTTP).
#   playwright          regular dependency whose install script downloads
#                       browsers -- PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 below,
#                       because a browser suite is a client-side thing and
#                       several hundred MiB of nothing in a gateway image.
#
# postinstall (scripts/build/postinstall.mjs) is NOT skipped: it is what
# populates dist/node_modules with the platform natives, and the published
# tarball deliberately ships no dist/node_modules of its own (`!**/node_modules/**`
# in files). If it ever grows a network fetch, the surgical fix is patching that
# step out, not OMNIROUTE_SKIP_POSTINSTALL=1 -- skipping the whole script takes
# the natives with it.
{ lib
, buildNpmPackage
, fetchurl
, fetchFromGitHub
, importNpmLock
, nodejs
, runCommand
, pkg-config
, libsecret
}:

let
  version = "3.8.51";

  src = fetchFromGitHub {
    owner = "diegosouzapw";
    repo = "OmniRoute";
    rev = "v${version}";
    hash = "sha256-ZYRjwynEw3cziFp8tM483QN96mDH0ZuHCFuhcJDwelA=";
  };

  prebuiltDist = fetchurl {
    url = "https://registry.npmjs.org/omniroute/-/omniroute-${version}.tgz";
    hash = "sha256-QhaZ/do0vYW88DUlfojjWe3AM8AbhdVLakkhwc2k0u8=";
  };

  # From the git tree's lock. importNpmLock rather than fetchNpmDeps: no hash
  # to maintain by hand, the lock is content-addressed, and workspace entries
  # (open-sse, packages/browser-pool) are link-resolved rather than fetched.
  npmDeps = importNpmLock { npmRoot = src; };

  # importNpmLock rewrites root dependencies/devDependencies to
  # file:/nix/store/... store paths but leaves `overrides` (and
  # optionalDependencies/peerDependencies) as the original semver ranges.
  # Upstream pins sharp, uuid, onnxruntime-node, eslint-plugin-react-hooks
  # and vite through BOTH a direct dependency and a top-level override
  # carrying the same range. When the dependency side is a store path and
  # the override is still a range, npm refuses to install:
  #
  #   npm error code EOVERRIDE
  #   npm error Override for sharp@file:/nix/store/...-sharp-0.35.4.tgz
  #          conflicts with direct dependency
  #
  # Measured, not theorised (build1/build5 logs). The naive fix -- deleting
  # the conflicting overrides -- breaks the tree (ENOTCACHED for uuid):
  # those overrides are load-bearing, they force a single version tree-wide
  # and the lock was resolved under them. The correct fix is to keep every
  # override but point the direct-dep ones at the SAME store path the
  # dependency was rewritten to, so override and dependency are identical
  # strings again. npm's EOVERRIDE rule is string equality between the
  # override and the direct dependency spec.
  #
  # Only dependencies/devDependencies are rewritten by importNpmLock (see
  # its packageJSON'), so only overrides naming a key in those two maps can
  # ever conflict. Object-valued overrides (nested, e.g. monaco-editor ->
  # dompurify) target a dependency OF a package, not the root's own
  # declaration, and are left alone.
  npmDepsFixed = runCommand "omniroute-npm-sources" { nativeBuildInputs = [ nodejs ]; } ''
    cp -a ${npmDeps} $out
    chmod -R u+w $out
    node -e "
      const fs = require('fs');
      const p = JSON.parse(fs.readFileSync('$out/package.json', 'utf8'));
      const overrides = p.overrides || {};
      const rewritten = Object.assign({}, p.dependencies, p.devDependencies);
      let changed = false;
      for (const key of Object.keys(overrides)) {
        if (typeof overrides[key] === 'string' && key in rewritten && overrides[key] !== rewritten[key]) {
          overrides[key] = rewritten[key];
          changed = true;
        }
      }
      if (changed) {
        fs.writeFileSync('$out/package.json', JSON.stringify(p, null, 2) + '\n');
      }
    "
  '';
in
buildNpmPackage {
  pname = "omniroute";
  inherit version src nodejs;

  # npmDeps, not the raw importNpmLock output: see npmDepsFixed above for the
  # EOVERRIDE fix (store-path overrides must match store-path deps).
  npmDeps = npmDepsFixed;

  # keytar (optionalDependency) has no usable prebuilt in the offline sandbox
  # -- prebuild-install fails to reach github.com -- so npm rebuild falls back
  # to node-gyp, which shells out to `pkg-config --cflags libsecret-1` while
  # parsing binding.gyp. Measured in build7: without these two the rebuild
  # dies on "pkg-config: command not found". libsecret is in buildInputs (not
  # just nativeBuildInputs) so the linked .node keeps it in the runtime
  # closure.
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libsecret ];

  # The npmConfigHook's rebuild phase runs install scripts for the whole
  # tree, including devDependency bun. bun's postinstall spawns its own
  # platform binary to verify it -- and @oven/bun-linux-x64 ships a generic
  # FHS dynamically linked executable, which the Nix sandbox cannot run
  # (exit 127, measured: "Could not start dynamically linked executable").
  # bun then falls back to an offline npm install / registry download and
  # the build dies. bun is dev-only: the image installs the packed tarball
  # globally (production deps, where keytar/better-sqlite3 get their install
  # scripts run with pkg-config available), so skipping the build-time
  # rebuild entirely costs nothing. Measured in build8 without this flag.
  npmRebuildFlags = [ "--ignore-scripts" ];

  # importNpmLock's own hook, NOT buildNpmPackage's bundled one. The bundled
  # hook validates that the src lockfile is byte-identical to the cache
  # lockfile ("npmDepsHash is out of date" otherwise) -- a check that is true
  # for fetchNpmDeps and can never be true for importNpmLock, whose entire job
  # is rewriting the lock's resolved fields to /nix/store paths. The hook
  # shipped with importNpmLock skips that check and installs from the
  # rewritten lock offline instead. Measured: without this line the build dies
  # on exactly that diff.
  npmConfigHook = importNpmLock.npmConfigHook;

  # dist/ is upstream's own build; see the file header.
  dontNpmBuild = true;

  env = {
    # Their prepare script execs husky when it resolves; husky is a devDep and
    # IS resolvable after npm ci, and it has no .git to install into. HUSKY=0
    # is husky's own documented opt-out.
    HUSKY = "0";

    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

    # Where node-gyp looks for headers when a prebuilt native falls back to a
    # source build. The nodejs package ships include/node, so this makes the
    # fallback work offline instead of dying on a headers download.
    npm_config_nodedir = nodejs;
  };

  postPatch = ''
    # Drop upstream's prebuilt Next.js output over the git tree's (empty of
    # dist) so npm pack below ships it and the install step never needs the
    # webpack build. The tarball's top-level directory is package/.
    tar -xzf ${prebuiltDist}
    rm -rf dist
    mv package/dist dist
    rm -rf package
  '';

  # npm pack's file list follows package.json "files", which has open-sse/
  # but not packages/ -- so packages/browser-pool never lands in the output
  # and node_modules/@omniroute/browser-pool (a workspace link to
  # ../../packages/browser-pool) dangles, tripping the fixup phase's
  # noBrokenSymlinks (measured in build9: exactly 1 dangling symlink).
  # Dropping the link matches the published shape: the npm tarball ships no
  # browser-pool files at all, and the only "browser-pool" strings in dist
  # are the embedded workspaces array of package.json -- no require() of the
  # package anywhere. The open-sse workspace link stays: it resolves to the
  # packed open-sse/ directory, which "files" does include.
  postInstall = ''
    rm -f "$out/lib/node_modules/omniroute/node_modules/@omniroute/browser-pool"
  '';

  meta = {
    description = "Open-source all-in-one AI gateway with load balancing, failover and a unified API";
    homepage = "https://github.com/diegosouzapw/OmniRoute";
    license = lib.licenses.mit;
    mainProgram = "omniroute";
    platforms = lib.platforms.linux;
  };
}
