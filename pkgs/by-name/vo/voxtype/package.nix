{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
  versionCheckHook,

  clang,
  cmake,
  gitMinimal,
  installShellFiles,
  libclang,
  makeBinaryWrapper,
  pkg-config,

  alsa-lib,
  dotool,
  libnotify,
  openssl,
  pciutils,
  pulseaudio,
  sqlite,
  wl-clipboard,
  wtype,
  which,
  xclip,
  xdotool,

  installManPages ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,
  installShellCompletions ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,

  vulkanSupport ? false,
  shaderc,
  spirv-headers,
  vulkan-headers,
  vulkan-loader,

  onnxSupport ? false,
  oniguruma,
  onnxruntime,

  hipSupport ? false,
  rocmPackages,
  rocmGpuTargets ? builtins.concatStringsSep ";" rocmPackages.clr.gpuTargets,

  waylandSupport ? stdenv.hostPlatform.isLinux,
  waylandRuntimePackages ? [
    dotool
    wl-clipboard
    wtype
  ],

  x11Support ? stdenv.hostPlatform.isLinux,
  x11RuntimePackages ? [
    xclip
    xdotool
  ],
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "voxtype";
  version = "1.2.2";

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "peteonrails";
    repo = "voxtype";
    tag = "v${finalAttrs.version}";
    hash = "sha256-9gXDvLS35we9aSqHoFYcG4Yby9mNRlKxjG+c4hGQqIM=";
  };

  # The optional OpenVINO git dependency vendors a symlink cycle in
  # thirdparty. Drop that unused tree rather than modifying Cargo.lock.
  # The OpenVINO Whisper engine is not part of these package variants.
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    postBuild = ''
      rm -r $out/git/*/crates/openvino-sys/upstream/thirdparty
    '';
    hash = "sha256-8ogR2P1EqfAHqPkj5AuVc9tjWQ6cYEtOVzH22WFa31c=";
  };

  buildFeatures =
    [ ]
    ++ lib.optionals vulkanSupport [ "gpu-vulkan" ]
    ++ lib.optionals hipSupport [ "gpu-hipblas" ]
    ++ lib.optionals onnxSupport [
      "parakeet-load-dynamic"
      "moonshine"
      "sensevoice"
      "paraformer"
      "dolphin"
      "omnilingual"
    ];

  nativeBuildInputs = [
    cmake
    clang
    gitMinimal # Required by whisper.cpp cmake
    installShellFiles
    makeBinaryWrapper
    pkg-config
  ]
  ++ lib.optionals hipSupport [
    rocmPackages.clr
  ]
  ++ lib.optionals vulkanSupport [
    shaderc
    vulkan-headers
    vulkan-loader
  ];

  buildInputs = [
    alsa-lib
    openssl
    sqlite
  ]
  ++ lib.optionals hipSupport (
    with rocmPackages;
    [
      clr
      hipblas
      rocblas
    ]
  )
  ++ lib.optionals vulkanSupport [
    spirv-headers
    vulkan-headers
    vulkan-loader
  ]
  ++ lib.optionals onnxSupport [
    oniguruma
    onnxruntime
  ];

  env = {
    # NOTE: set LIBCLANG_PATH so bindgen can locate libclang
    LIBCLANG_PATH = "${lib.getLib libclang}/lib";

    # NOTE: Ensure reproducible builds targeting AVX2-capable CPUs (x86-64-v3)
    # This matches the portable AVX2 binaries we ship for other distros
    RUSTFLAGS = lib.optionalString (
      stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64
    ) "-C target-cpu=x86-64-v3";
  }
  // lib.optionalAttrs hipSupport {
    HIP_PATH = "${rocmPackages.clr}";
    AMDGPU_TARGETS = rocmGpuTargets;
  };

  # whisper-rs-sys 0.15.0's ggml Vulkan generator retains a future per shader.
  # Compile synchronously, and reject missing SPIR-V rather than failing to
  # link hundreds of undefined matmul_* symbols on resource-limited builders.
  postPatch = lib.optionalString vulkanSupport ''
    shaderGen="$cargoDepsCopy/source-registry-0/whisper-rs-sys-0.15.0/whisper.cpp/ggml/src/ggml-vulkan/vulkan-shaders/vulkan-shaders-gen.cpp"
    test -f "$shaderGen"
    substituteInPlace "$shaderGen" \
      --replace-fail \
      '    compiles.push_back(std::async(
            string_to_spv_func, name, input_filepath, out_path, defines, coopmat, generate_dep_file, std::move(slot)));' \
      '    string_to_spv_func(name, input_filepath, out_path, defines, coopmat, generate_dep_file, std::move(slot));'
    substituteInPlace "$shaderGen" \
      --replace-fail \
      '            if (data.empty()) {
                    continue;
                }' \
      '            if (data.empty()) {
                    throw std::runtime_error("Missing compiled Vulkan shader: " + name + " (" + path + ")");
                }'
    substituteInPlace "$shaderGen" \
      --replace-fail \
      'std::cerr << "\n\n" << stderr_str << std::endl;' \
      'std::cerr << "\n\n" << stderr_str << std::endl; throw std::runtime_error("Vulkan shader compilation failed: " + name);'
    substituteInPlace "$shaderGen" \
      --replace-fail \
      'std::cerr << "Error executing command for " << name << ": " << e.what() << std::endl;' \
      'std::cerr << "Error executing command for " << name << ": " << e.what() << std::endl; throw;'
  '';

  preBuild = ''
    # cmake-rs uses Cargo's job count as an explicit --parallel argument.
    # Bound both for the shader-heavy Vulkan build.
    ${lib.optionalString vulkanSupport "export NIX_BUILD_CORES=1"}
    export CMAKE_BUILD_PARALLEL_LEVEL=$NIX_BUILD_CORES
  ''
  + lib.optionalString vulkanSupport ''
    export VULKAN_SDK="${shaderc.bin}"
    export Vulkan_INCLUDE_DIR="${vulkan-headers}/include"
    export Vulkan_LIBRARY="${vulkan-loader}/lib/libvulkan.so"
  ''
  + lib.optionalString onnxSupport ''
    export ORT_LIB_LOCATION="${lib.getLib onnxruntime}/lib"
  '';

  # GGUF inference is a separate workspace binary; the daemon finds it
  # beside its executable. It must be built with the same Vulkan feature.
  postBuild = lib.optionalString vulkanSupport ''
    cargo build --offline --jobs 1 \
      --target ${stdenv.hostPlatform.rust.cargoShortTarget} \
      --profile release \
      -p voxtype-gguf-worker --features vulkan
  '';

  postInstall = ''
    ${lib.optionalString vulkanSupport ''
      install -Dm755 target/${stdenv.hostPlatform.rust.cargoShortTarget}/release/voxtype-gguf-worker \
        $out/bin/voxtype-gguf-worker
    ''}
    install -Dm644 config/default.toml \
      $out/share/voxtype/default-config.toml

    wrapProgram $out/bin/voxtype \
      --prefix PATH : ${
        (lib.makeBinPath (
          [
            libnotify
            pulseaudio # pactl for media ducking
            which
          ]
          ++ lib.optionals vulkanSupport [
            pciutils
          ]
          ++ lib.optionals waylandSupport waylandRuntimePackages
          ++ lib.optionals x11Support x11RuntimePackages
        ))
        + lib.optionalString onnxSupport " \\"
      }
      ${lib.optionalString onnxSupport ''
        --set ORT_DYLIB_PATH "${lib.getLib onnxruntime}/lib/libonnxruntime.so" \
        --prefix LD_LIBRARY_PATH : "${lib.getLib onnxruntime}/lib"
      ''}
  ''
  + lib.optionalString installManPages ''
    installManPage target/${stdenv.hostPlatform.rust.cargoShortTarget}/$cargoBuildType/build/voxtype-*/out/man/*
  ''
  + lib.optionalString installShellCompletions ''
    installShellCompletion packaging/completions/voxtype.{bash,zsh,fish}
  '';

  nativeInstallCheckInputs = [
    versionCheckHook
  ];
  doInstallCheck = true;

  passthru.update-script = nix-update-script { };

  meta = {
    description = "Voice-to-text with push-to-talk for Wayland compositors";
    longDescription = ''
      Voxtype is a push-to-talk voice-to-text daemon for Linux.
      Hold a hotkey while speaking, release to transcribe and output
      text at your cursor position. Supports Whisper, Parakeet,
      SenseVoice, Moonshine, Paraformer, Dolphin, and Omnilingual engines.
    '';
    homepage = "https://voxtype.io";
    downloadPage = "https://voxtype.io/download/";
    changelog = "https://github.com/peteonrails/voxtype/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      DuskyElf
      pbek
    ];
    platforms = lib.platforms.linux;
    mainProgram = "voxtype";
  };
})
