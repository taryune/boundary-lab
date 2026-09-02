{
  description = "Boundary Lab development shell (Nix system layer + pip/uv Python layer)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          inherit (pkgs) lib;

          python = pkgs.python311;

          # Runtime shared libraries needed by the manylinux wheels installed into
          # .venv (PySide6, pyvista/VTK, gmsh, pyopencl, numpy/scipy).
          runtimeLibs = with pkgs; [
            stdenv.cc.cc.lib
            zlib
            zstd
            bzip2
            xz
            openssl
            curl
            expat
            libffi

            # OpenGL / graphics
            libglvnd
            libGL
            libGLU
            mesa
            wayland
            libxkbcommon

            # X11 / XCB (Qt xcb platform plugin, VTK)
            libx11
            libxext
            libxrender
            libxi
            libxrandr
            libxcursor
            libxcomposite
            libxdamage
            libxtst
            libxfixes
            libxxf86vm
            libxinerama
            libxft
            libxpm
            libsm
            libice
            libxcb
            libxcb-util
            libxcb-image
            libxcb-keysyms
            libxcb-render-util
            libxcb-wm
            libxcb-cursor

            # Fonts / desktop integration
            fontconfig
            freetype
            dbus
            glib
            nspr
            nss
            alsa-lib
            pulseaudio

            # OpenCL loader (pyopencl links against libOpenCL.so)
            ocl-icd
          ];

          libraryPath = lib.makeLibraryPath runtimeLibs;
        in
        {
          default = pkgs.mkShell {
            name = "boundary-lab";

            nativeBuildInputs = with pkgs; [
              python
              uv
              julia
              git
              cmake
              pkg-config
              gcc
              patchelf
              findutils
              # Bempp OpenCL CPU backend
              pocl
              ocl-icd
              clinfo
              # Bundled Ath geometry generator (Windows binary, run through wine)
              wineWow64Packages.stable
            ];

            buildInputs = runtimeLibs;

            # Keep nixpkgs Qt hooks away from the PySide6 wheel, which ships its
            # own Qt build and its own platform plugins.
            dontWrapQtApps = true;

            shellHook = ''
              set -u
              repo_root="$PWD"
              # Exported so shell functions defined below (which are exported to
              # subshells via `export -f`) can still resolve the repository.
              export BLAB_REPO_ROOT="$repo_root"

              # ---------------------------------------------------------------
              # Shared library resolution for manylinux wheels.
              # /run/opengl-driver/lib provides libcuda.so and the GLX/EGL vendor
              # libraries on NixOS.
              # ---------------------------------------------------------------
              export LD_LIBRARY_PATH="${libraryPath}:/run/opengl-driver/lib:/run/opengl-driver-32/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              # ---------------------------------------------------------------
              # Qt: let the PySide6 wheel use its bundled plugins.
              # ---------------------------------------------------------------
              unset QT_PLUGIN_PATH QML2_IMPORT_PATH QML_IMPORT_PATH QT_QPA_PLATFORM_PLUGIN_PATH
              export QT_XKB_CONFIG_ROOT="${pkgs.xkeyboard_config}/share/X11/xkb"
              # Only provide a fontconfig when the host has none (NixOS supplies
              # /etc/fonts/fonts.conf, which knows about the user's fonts).
              if [ ! -f /etc/fonts/fonts.conf ]; then
                export FONTCONFIG_FILE="${pkgs.fontconfig.out}/etc/fonts/fonts.conf"
              fi
              # The VTK wheel ships an X11-only OpenGL render window
              # (vtkXOpenGLRenderWindow). Under the Qt wayland platform the
              # 3D viewport receives a Wayland surface handle and dies with
              # "BadWindow (invalid Window parameter)", so force XWayland.
              # Wayland sessions normally export QT_QPA_PLATFORM=wayland, so this
              # is overridden unless BLAB_QT_QPA_PLATFORM asks for something else.
              export QT_QPA_PLATFORM="''${BLAB_QT_QPA_PLATFORM:-xcb}"

              # ---------------------------------------------------------------
              # OpenCL: expose only the pocl ICD so pyopencl has a known-good CPU
              # platform. Append the host ICD directory if the machine has one.
              # ---------------------------------------------------------------
              export OCL_ICD_VENDORS="${pkgs.pocl}/etc/OpenCL/vendors"
              # pocl segfaults inside Bempp's explicitly vectorised Helmholtz
              # kernels (any of vec4/vec8/vec16, every POCL_DEVICES/work-group
              # method). The scalar kernels are stable, so opt out here.
              export BLAB_BEMPP_VECTORIZATION_MODE="''${BLAB_BEMPP_VECTORIZATION_MODE:-novec}"

              # ---------------------------------------------------------------
              # Julia / BEAT Engine
              # ---------------------------------------------------------------
              export BLAB_JULIA_EXE="$(command -v julia)"
              export BLAB_JULIA_EXECUTABLE="$BLAB_JULIA_EXE"
              export JULIA_DEPOT_PATH="$repo_root/.julia-depot"
              export JULIA_NUM_THREADS="''${JULIA_NUM_THREADS:-auto}"

              # Julia artifacts (CUDA.jl toolchain: llc, ptxas, cuda_inspect_driver,
              # ...) are generic-linux binaries that NixOS cannot exec because
              # their ELF interpreter does not exist here. Rewrite the interpreter
              # and RPATH so they run. Safe to re-run; already-patched binaries are
              # skipped.
              export BLAB_NIX_DYNAMIC_LINKER="${pkgs.stdenv.cc.bintools.dynamicLinker}"
              export BLAB_NIX_LIBRARY_PATH="${libraryPath}:/run/opengl-driver/lib"

              # Rewrites the ELF interpreter and RPATH of prebuilt generic-linux
              # executables in $1 so they can run on NixOS. Idempotent: binaries
              # already pointing at a /nix/store interpreter are skipped.
              blab-patch-foreign-bins() {
                local root="$1"
                [ -d "$root" ] || return 0
                local patched=0 f interp dir
                while IFS= read -r f; do
                  interp="$(patchelf --print-interpreter "$f" 2>/dev/null)" || continue
                  [ -n "$interp" ] || continue
                  case "$interp" in
                    /nix/store/*) continue ;;
                  esac
                  # Julia artifact trees are installed read-only.
                  dir="$(dirname "$f")"
                  chmod u+w "$dir" "$f" 2>/dev/null || true
                  if patchelf --set-interpreter "$BLAB_NIX_DYNAMIC_LINKER" \
                              --set-rpath "$BLAB_NIX_LIBRARY_PATH:$dir/../lib" "$f"; then
                    patched=$((patched + 1))
                  fi
                done < <(find "$root" -type f -perm -u+x 2>/dev/null)
                echo "==> patched $patched foreign executable(s) under $root"
              }
              export -f blab-patch-foreign-bins 2>/dev/null || true

              blab-patch-julia-artifacts() {
                blab-patch-foreign-bins "''${JULIA_DEPOT_PATH%%:*}/artifacts"
              }
              export -f blab-patch-julia-artifacts 2>/dev/null || true

              blab-julia-setup() {
                # Instantiates the BEAT Engine Julia environments. The CUDA
                # project downloads several hundred MB of artifacts.
                local projects="julia_local"
                local cuda=0
                if [ "''${1:-}" = "--cuda" ] || [ "''${1:-}" = "--all" ]; then
                  projects="julia_local julia_cuda"
                  cuda=1
                fi
                local p
                for p in $projects; do
                  echo "==> instantiating src/blab/solvers/$p"
                  julia --project="$BLAB_REPO_ROOT/src/blab/solvers/$p" \
                    -e 'using Pkg; Pkg.instantiate()' || return 1
                  if [ "$p" = "julia_cuda" ]; then
                    blab-patch-julia-artifacts
                    # CUDA_Runtime_jll caches driver detection at precompile
                    # time; the first (pre-patch) attempt sees no driver, so
                    # invalidate that cache once the artifacts are runnable.
                    echo "==> re-compiling CUDA_Runtime_jll driver detection"
                    julia --project="$BLAB_REPO_ROOT/src/blab/solvers/$p" -e '
                      pkg = Base.PkgId(Base.UUID("76a88914-d11a-5bdc-97e0-2f5a05c973a2"),
                                       "CUDA_Runtime_jll")
                      Base.compilecache(pkg)' || return 1
                  fi
                  echo "==> precompiling src/blab/solvers/$p"
                  julia --project="$BLAB_REPO_ROOT/src/blab/solvers/$p" \
                    -e 'using Pkg; Pkg.precompile()' || return 1
                done
              }
              export -f blab-julia-setup 2>/dev/null || true

              # ---------------------------------------------------------------
              # Python virtualenv (.venv), bootstrapped with uv.
              # ---------------------------------------------------------------
              export UV_PYTHON="${python}/bin/python3.11"
              export UV_PYTHON_DOWNLOADS=never
              venv="$repo_root/.venv"
              stamp="$venv/.blab-install-stamp"

              if [ ! -d "$venv" ]; then
                echo "==> creating .venv (python 3.11)"
                uv venv --python "$UV_PYTHON" "$venv" || return 1
              fi
              # shellcheck disable=SC1091
              source "$venv/bin/activate"
              # Point uv at the venv interpreter, not the (externally managed)
              # nix store interpreter used to create it.
              export UV_PYTHON="$venv/bin/python"
              export VIRTUAL_ENV="$venv"

              if [ ! -f "$stamp" ] || [ "$repo_root/pyproject.toml" -nt "$stamp" ]; then
                echo "==> installing boundary-lab (editable) with gui+dev extras"
                if uv pip install -e "$repo_root[gui,dev]"; then
                  # Some wheels (e.g. ruff) ship generic-linux executables.
                  blab-patch-foreign-bins "$venv/bin" >/dev/null
                  touch "$stamp"
                else
                  echo "!! dependency install failed; fix and re-enter the shell" >&2
                fi
              fi

              # ---------------------------------------------------------------
              # Status banner
              # ---------------------------------------------------------------
              echo
              echo "boundary-lab dev shell"
              echo "  python : $(python --version 2>&1)  ($venv)"
              echo "  julia  : $(julia --version 2>&1)"
              echo "  opencl : OCL_ICD_VENDORS=$OCL_ICD_VENDORS"
              if command -v nvidia-smi >/dev/null 2>&1; then
                echo "  nvidia : $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
              else
                echo "  nvidia : nvidia-smi not found (CUDA solver unavailable)"
              fi
              echo
              echo "  blab-julia-setup [--cuda]   instantiate BEAT Engine Julia projects"
              echo "  blab gui                    launch the desktop application"
              echo
              set +u
            '';
          };
        });
    };
}
