#!/bin/bash

# --- Environment Setup ---
ROOT_DIR=$(pwd)
LIBS_DIR="$ROOT_DIR/Libraries"
THIRDPARTY_DIR="$ROOT_DIR/ThirdParty"
USED_PREFIX="$LIBS_DIR/local"
PATH_PREFIX="$ROOT_DIR/ThirdParty/gyp:$ROOT_DIR/ThirdParty/yasm:$ROOT_DIR/ThirdParty/depot_tools:"

export USED_PREFIX="$USED_PREFIX"
export ROOT_DIR="$ROOT_DIR"
export LIBS_DIR="$LIBS_DIR"
export THIRDPARTY_DIR="$THIRDPARTY_DIR"
export PATH_PREFIX="$PATH_PREFIX"

export SPECIAL_TARGET="mac"
export MAKE_THREADS_CNT="-j$(sysctl -n hw.logicalcpu_max)"
export MACOSX_DEPLOYMENT_TARGET="10.13"
export UNGUARDED="-Werror=unguarded-availability-new"
export MIN_VER="-mmacosx-version-min=10.13"

export PATH="$PATH_PREFIX:$PATH"

# --- Helper Functions ---
remove_dir() {
  folder="$1"
  echo "Removing directory: $folder"
  rm -rf "$folder"
}

create_dir() {
  folder="$1"
  echo "Creating directory: $folder"
  mkdir -p "$folder"
}

run_stage() {
  stage_name="$1"
  build_type="$2" # "Debug" or "Release"
  commands="$3"

  echo "-------------------------------------------------------------------------"
  echo "Stage: $stage_name - Build Type: $build_type"
  echo "-------------------------------------------------------------------------"

  if [ "$build_type" == "Debug" ]; then
    commands=$(echo "$commands" | sed -n '/debug:/,/release:/p' | grep -v -e 'debug:' -e 'release:')
  elif [ "$build_type" == "Release" ]; then
    commands=$(echo "$commands" | sed -n '/release:/,/debug:/p' | grep -v -e 'release:' -e 'debug:')
  else
    commands=$(echo "$commands" | grep -v -e 'debug:' -e 'release:')
  fi

  commands=$(echo "$commands" | grep -v '^win:') # Remove win specific lines

  echo "Commands:"
  echo "$commands"

  eval "$commands" || return 1

  echo "Stage '$stage_name' - '$build_type' completed successfully."
  echo "-------------------------------------------------------------------------"
}


# --- Stages ---

# patches
STAGE_PATCHES_COMMANDS="
  git clone https://github.com/desktop-app/patches.git
  cd patches
  git checkout 8828ed7f66
"
run_stage "patches" "Common" "$STAGE_PATCHES_COMMANDS" || exit 1

# depot_tools
STAGE_DEPOT_TOOLS_COMMANDS="
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
  cd depot_tools
  ./update_depot_tools
"
run_stage "depot_tools" "Common" "$STAGE_DEPOT_TOOLS_COMMANDS" || exit 1

# gyp
STAGE_GYP_COMMANDS="
  python3 -m pip install \\
    --ignore-installed \\
    --target=\"\$THIRDPARTY_DIR/gyp\" \\
    git+https://chromium.googlesource.com/external/gyp@master
"
run_stage "gyp" "Common" "$STAGE_GYP_COMMANDS" || exit 1

# yasm
STAGE_YASM_COMMANDS="
  git clone https://github.com/yasm/yasm.git
  cd yasm
  git checkout 41762bea
  ./autogen.sh
  make \$MAKE_THREADS_CNT
"
run_stage "yasm" "Common" "$STAGE_YASM_COMMANDS" || exit 1

# xz
STAGE_XZ_COMMANDS="
  git clone -b v5.4.5 https://github.com/tukaani-project/xz.git
  cd xz
  sed -i '' '\\@check_symbol_exists(futimens \"sys/types.h;sys/stat.h\" HAVE_FUTIMENS)@d' CMakeLists.txt
  CFLAGS=\"\$UNGUARDED\" CPPFLAGS=\"\$UNGUARDED\" cmake -B build . \\
    -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
    -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
    -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX
  cmake --build build \$MAKE_THREADS_CNT
  cmake --install build
"
run_stage "xz" "Common" "$STAGE_XZ_COMMANDS" || exit 1

# zlib
STAGE_ZLIB_COMMANDS="
  git clone https://github.com/madler/zlib.git
  cd zlib
  git checkout 643e17b749
  debug:
    CFLAGS=\"\$MIN_VER \$UNGUARDED\" LDFLAGS=\"\$MIN_VER\" ./configure \\
      --static \\
      --prefix=\$USED_PREFIX \\
      --archs=\"-arch x86_64 -arch arm64\"
    make \$MAKE_THREADS_CNT
    make install
  release:
    CFLAGS=\"\$MIN_VER \$UNGUARDED\" LDFLAGS=\"\$MIN_VER\" ./configure \\
      --static \\
      --prefix=\$USED_PREFIX \\
      --archs=\"-arch x86_64 -arch arm64\"
    make \$MAKE_THREADS_CNT
    make install
"
run_stage "zlib" "Debug" "$STAGE_ZLIB_COMMANDS" || exit 1
run_stage "zlib" "Release" "$STAGE_ZLIB_COMMANDS" || exit 1

# mozjpeg
STAGE_MOZJPEG_COMMANDS="
  git clone -b v4.1.5 https://github.com/mozilla/mozjpeg.git
  cd mozjpeg
  release:
    CFLAGS=\"-arch arm64\" cmake -B build.arm64 . \\
      -D CMAKE_SYSTEM_NAME=Darwin \\
      -D CMAKE_SYSTEM_PROCESSOR=arm64 \\
      -D CMAKE_BUILD_TYPE=Release \\
      -D CMAKE_INSTALL_PREFIX=\$USED_PREFIX \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D WITH_JPEG8=ON \\
      -D ENABLE_SHARED=OFF \\
      -D PNG_SUPPORTED=OFF
    cmake --build build.arm64 \$MAKE_THREADS_CNT
    CFLAGS=\"-arch x86_64\" cmake -B build . \\
      -D CMAKE_SYSTEM_NAME=Darwin \\
      -D CMAKE_SYSTEM_PROCESSOR=x86_64 \\
      -D CMAKE_BUILD_TYPE=Release \\
      -D CMAKE_INSTALL_PREFIX=\$USED_PREFIX \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D WITH_JPEG8=ON \\
      -D ENABLE_SHARED=OFF \\
      -D PNG_SUPPORTED=OFF
    cmake --build build \$MAKE_THREADS_CNT
    lipo -create build.arm64/libjpeg.a build/libjpeg.a -output build/libjpeg.a
    lipo -create build.arm64/libturbojpeg.a build/libturbojpeg.a -output build/libturbojpeg.a
    cmake --install build
  debug: # Assuming debug is similar to release for mac in this context, adjust if needed
    CFLAGS=\"-arch arm64\" cmake -B build.arm64 . \\
      -D CMAKE_SYSTEM_NAME=Darwin \\
      -D CMAKE_SYSTEM_PROCESSOR=arm64 \\
      -D CMAKE_BUILD_TYPE=Debug \\
      -D CMAKE_INSTALL_PREFIX=\$USED_PREFIX \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D WITH_JPEG8=ON \\
      -D ENABLE_SHARED=OFF \\
      -D PNG_SUPPORTED=OFF
    cmake --build build.arm64 \$MAKE_THREADS_CNT
    CFLAGS=\"-arch x86_64\" cmake -B build . \\
      -D CMAKE_SYSTEM_NAME=Darwin \\
      -D CMAKE_SYSTEM_PROCESSOR=x86_64 \\
      -D CMAKE_BUILD_TYPE=Debug \\
      -D CMAKE_INSTALL_PREFIX=\$USED_PREFIX \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D WITH_JPEG8=ON \\
      -D ENABLE_SHARED=OFF \\
      -D PNG_SUPPORTED=OFF
    cmake --build build \$MAKE_THREADS_CNT
    lipo -create build.arm64/libjpeg.a build/libjpeg.a -output build/libjpeg.a
    lipo -create build.arm64/libturbojpeg.a build/libturbojpeg.a -output build/libturbojpeg.a
    cmake --install build
"
run_stage "mozjpeg" "Debug" "$STAGE_MOZJPEG_COMMANDS" || exit 1
run_stage "mozjpeg" "Release" "$STAGE_MOZJPEG_COMMANDS" || exit 1

# openssl3
STAGE_OPENSSL3_COMMANDS="
  git clone -b openssl-3.2.1 https://github.com/openssl/openssl openssl3
  cd openssl3
  mac:
    debug:
      ./Configure --prefix=\$USED_PREFIX no-shared no-tests darwin64-arm64-cc \$MIN_VER
      make build_libs \$MAKE_THREADS_CNT
      create_dir out.arm64
      mv libssl.a out.arm64
      mv libcrypto.a out.arm64
      make clean
      ./Configure --prefix=\$USED_PREFIX no-shared no-tests darwin64-x86_64-cc \$MIN_VER
      make build_libs \$MAKE_THREADS_CNT
      create_dir out.x86_64
      mv libssl.a out.x86_64
      mv libcrypto.a out.x86_64
      lipo -create out.arm64/libcrypto.a out.x86_64/libcrypto.a -output libcrypto.a
      lipo -create out.arm64/libssl.a out.x86_64/libssl.a -output libssl.a
    release:
      ./Configure --prefix=\$USED_PREFIX no-shared no-tests darwin64-arm64-cc \$MIN_VER
      make build_libs \$MAKE_THREADS_CNT
      create_dir out.arm64
      mv libssl.a out.arm64
      mv libcrypto.a out.arm64
      make clean
      ./Configure --prefix=\$USED_PREFIX no-shared no-tests darwin64-x86_64-cc \$MIN_VER
      make build_libs \$MAKE_THREADS_CNT
      create_dir out.x86_64
      mv libssl.a out.x86_64
      mv libcrypto.a out.x86_64
      lipo -create out.arm64/libcrypto.a out.x86_64/libcrypto.a -output libcrypto.a
      lipo -create out.arm64/libssl.a out.x86_64/libssl.a -output libssl.a
"
run_stage "openssl3" "Debug" "$STAGE_OPENSSL3_COMMANDS" || exit 1
run_stage "openssl3" "Release" "$STAGE_OPENSSL3_COMMANDS" || exit 1

# opus
STAGE_OPUS_COMMANDS="
  git clone -b v1.3.1 https://github.com/xiph/opus.git
  cd opus
  git cherry-pick 927de8453c
  mac:
    CFLAGS=\"\$UNGUARDED\" CPPFLAGS=\"\$UNGUARDED\" cmake -B build . \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX
    cmake --build build \$MAKE_THREADS_CNT
    cmake --install build
"
run_stage "opus" "Debug" "$STAGE_OPUS_COMMANDS" || exit 1 # Assuming same for debug/release
run_stage "opus" "Release" "$STAGE_OPUS_COMMANDS" || exit 1

# rnnoise
STAGE_RNNOISE_COMMANDS="
  git clone https://github.com/desktop-app/rnnoise.git
  cd rnnoise
  git checkout fe37e57d09
  create_dir out
  cd out
  !win:
    debug:
      create_dir Debug
      cd Debug
      cmake -G Ninja ../.. -D CMAKE_BUILD_TYPE=Debug -D CMAKE_OSX_ARCHITECTURES=\"arm64\" --trace-expand
      ninja
    release:
      cd ..
      create_dir Release
      cd Release
      cmake -G Ninja ../.. -D CMAKE_BUILD_TYPE=Release -D CMAKE_OSX_ARCHITECTURES=\"arm64\" --trace-expand
      ninja
"
run_stage "rnnoise" "Debug" "$STAGE_RNNOISE_COMMANDS" || exit 1
run_stage "rnnoise" "Release" "$STAGE_RNNOISE_COMMANDS" || exit 1

# libiconv
STAGE_LIBICONV_COMMANDS="
  VERSION=1.17
  rm -f libiconv.tar.gz
  wget -O libiconv.tar.gz ftp://ftp.gnu.org/gnu/libiconv/libiconv-\$VERSION.tar.gz
  rm -rf libiconv-\$VERSION
  tar -xvzf libiconv.tar.gz
  rm libiconv.tar.gz
  mv libiconv-\$VERSION libiconv
  cd libiconv
  debug:
    CFLAGS=\"\$MIN_VER \$UNGUARDED -arch arm64\" CPPFLAGS=\"\$MIN_VER \$UNGUARDED -arch arm64\" LDFLAGS=\"\$MIN_VER\" ./configure --enable-static --host=arm --prefix=\$USED_PREFIX
    make \$MAKE_THREADS_CNT
    create_dir out.arm64
    mv lib/.libs/libiconv.a out.arm64
    make clean
    CFLAGS=\"\$MIN_VER \$UNGUARDED -arch x86_64\" CPPFLAGS=\"\$MIN_VER \$UNGUARDED -arch x86_64\" LDFLAGS=\"\$MIN_VER\" ./configure --enable-static --host=x86_64 --prefix=\$USED_PREFIX
    make \$MAKE_THREADS_CNT
    create_dir out.x86_64
    mv lib/.libs/libiconv.a out.x86_64
    lipo -create out.arm64/libiconv.a out.x86_64/libiconv.a -output lib/.libs/libiconv.a
    make install
  release:
    CFLAGS=\"\$MIN_VER \$UNGUARDED -arch arm64\" CPPFLAGS=\"\$MIN_VER \$UNGUARDED -arch arm64\" LDFLAGS=\"\$MIN_VER\" ./configure --enable-static --host=arm --prefix=\$USED_PREFIX
    make \$MAKE_THREADS_CNT
    create_dir out.arm64
    mv lib/.libs/libiconv.a out.arm64
    make clean
    CFLAGS=\"\$MIN_VER \$UNGUARDED -arch x86_64\" CPPFLAGS=\"\$MIN_VER \$UNGUARDED -arch x86_64\" LDFLAGS=\"\$MIN_VER\" ./configure --enable-static --host=x86_64 --prefix=\$USED_PREFIX
    make \$MAKE_THREADS_CNT
    create_dir out.x86_64
    mv lib/.libs/libiconv.a out.x86_64
    lipo -create out.arm64/libiconv.a out.x86_64/libiconv.a -output lib/.libs/libiconv.a
    make install
"
run_stage "libiconv" "Debug" "$STAGE_LIBICONV_COMMANDS" || exit 1
run_stage "libiconv" "Release" "$STAGE_LIBICONV_COMMANDS" || exit 1

# dav1d
STAGE_DAV1D_COMMANDS="
  git clone -b 1.4.1 https://code.videolan.org/videolan/dav1d.git
  cd dav1d
  mac:
    buildOneArch() {
      arch=\"\$1\"
      folder=\"\$(pwd)/\$2\"

      meson setup \\
        --cross-file ../patches/macos_meson_\${arch}.txt \\
        --prefix \$USED_PREFIX \\
        --default-library=static \\
        --buildtype=debug \\
        -Denable_tools=false \\
        -Denable_tests=false \\
        \${folder}
      meson compile -C \${folder}
      meson install -C \${folder}

      mv \$USED_PREFIX/lib/libdav1d.a \${folder}/libdav1d.a
    }
    debug:
      buildOneArch arm64 build.arm64
      buildOneArch x86_64 build

      lipo -create build.arm64/libdav1d.a build/libdav1d.a -output \$USED_PREFIX/lib/libdav1d.a

    buildOneArchRelease() {
      arch=\"\$1\"
      folder=\"\$(pwd)/\$2\"

      meson setup \\
        --cross-file ../patches/macos_meson_\${arch}.txt \\
        --prefix \$USED_PREFIX \\
        --default-library=static \\
        --buildtype=minsize \\
        -Denable_tools=false \\
        -Denable_tests=false \\
        \${folder}
      meson compile -C \${folder}
      meson install -C \${folder}

      mv \$USED_PREFIX/lib/libdav1d.a \${folder}/libdav1d.a
    }
    release:
      buildOneArchRelease arm64 build.arm64
      buildOneArchRelease x86_64 build

      lipo -create build.arm64/libdav1d.a build/libdav1d.a -output \$USED_PREFIX/lib/libdav1d.a
"
run_stage "dav1d" "Debug" "$STAGE_DAV1D_COMMANDS" || exit 1
run_stage "dav1d" "Release" "$STAGE_DAV1D_COMMANDS" || exit 1


# openh264
STAGE_OPENH264_COMMANDS="
  git clone -b v2.4.1 https://github.com/cisco/openh264.git
  cd openh264
  mac:
    buildOneArch() {
      arch=\"\$1\"
      folder=\"\$(pwd)/\$2\"

      meson setup \\
        --cross-file ../patches/macos_meson_\${arch}.txt \\
        --prefix \$USED_PREFIX \\
        --default-library=static \\
        --buildtype=debug \\ # Assuming debug is needed here as well, adjust if needed
        \${folder}
      meson compile -C \${folder}
      meson install -C \${folder}

      mv \$USED_PREFIX/lib/libopenh264.a \${folder}/libopenh264.a
    }
    debug:
      buildOneArch aarch64 build.aarch64
      buildOneArch x86_64 build.x86_64

      lipo -create build.aarch64/libopenh264.a build.x86_64/libopenh264.a -output \$USED_PREFIX/lib/libopenh264.a

    buildOneArchRelease() {
      arch=\"\$1\"
      folder=\"\$(pwd)/\$2\"

      meson setup \\
        --cross-file ../patches/macos_meson_\${arch}.txt \\
        --prefix \$USED_PREFIX \\
        --default-library=static \\
        --buildtype=minsize \\
        \${folder}
      meson compile -C \${folder}
      meson install -C \${folder}

      mv \$USED_PREFIX/lib/libopenh264.a \${folder}/libopenh264.a
    }
    release:
      buildOneArchRelease aarch64 build.aarch64
      buildOneArchRelease x86_64 build.x86_64

      lipo -create build.aarch64/libopenh264.a build.x86_64/libopenh264.a -output \$USED_PREFIX/lib/libopenh264.a
"
run_stage "openh264" "Debug" "$STAGE_OPENH264_COMMANDS" || exit 1
run_stage "openh264" "Release" "$STAGE_OPENH264_COMMANDS" || exit 1

# libavif
STAGE_LIBAVIF_COMMANDS="
  git clone -b v1.0.4 https://github.com/AOMediaCodec/libavif.git
  cd libavif
  mac:
    cmake . \\
      -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX \\
      -D BUILD_SHARED_LIBS=OFF \\
      -D AVIF_ENABLE_WERROR=OFF \\
      -D AVIF_CODEC_DAV1D=ON \\
      -D CMAKE_DISABLE_FIND_PACKAGE_libsharpyuv=ON
    debug:
      cmake --build . --config Debug \$MAKE_THREADS_CNT
      cmake --install . --config Debug
    release:
      cmake --build . --config MinSizeRel \$MAKE_THREADS_CNT
      cmake --install . --config MinSizeRel
"
run_stage "libavif" "Debug" "$STAGE_LIBAVIF_COMMANDS" || exit 1
run_stage "libavif" "Release" "$STAGE_LIBAVIF_COMMANDS" || exit 1

# libde265
STAGE_LIBDE265_COMMANDS="
  git clone -b v1.0.15 https://github.com/strukturag/libde265.git
  cd libde265
  mac:
    cmake . \\
      -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX \\
      -D DISABLE_SSE=ON \\
      -D ENABLE_SDL=OFF \\
      -D BUILD_SHARED_LIBS=OFF \\
      -D ENABLE_DECODER=ON \\
      -D ENABLE_ENCODER=OFF
    debug:
      cmake --build . --config Debug \$MAKE_THREADS_CNT # Assuming debug is also MinSizeRel for mac
      cmake --install . --config Debug # Assuming debug is also MinSizeRel for mac
    release:
      cmake --build . --config MinSizeRel \$MAKE_THREADS_CNT
      cmake --install . --config MinSizeRel
"
run_stage "libde265" "Debug" "$STAGE_LIBDE265_COMMANDS" || exit 1
run_stage "libde265" "Release" "$STAGE_LIBDE265_COMMANDS" || exit 1

# libwebp
STAGE_LIBWEBP_COMMANDS="
  git clone -b v1.4.0 https://github.com/webmproject/libwebp.git
  cd libwebp
  mac:
    buildOneArch() {
      arch=\"\$1\"
      folder=\$2

      CFLAGS=\$UNGUARDED cmake -B \$folder -G Ninja . \\
        -D CMAKE_BUILD_TYPE=Release \\
        -D CMAKE_INSTALL_PREFIX=\$USED_PREFIX \\
        -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
        -D CMAKE_OSX_ARCHITECTURES=\$arch \\
        -D WEBP_BUILD_ANIM_UTILS=OFF \\
        -D WEBP_BUILD_CWEBP=OFF \\
        -D WEBP_BUILD_DWEBP=OFF \\
        -D WEBP_BUILD_GIF2WEBP=OFF \\
        -D WEBP_BUILD_IMG2WEBP=OFF \\
        -D WEBP_BUILD_VWEBP=OFF \\
        -D WEBP_BUILD_WEBPMUX=OFF \\
        -D WEBP_BUILD_WEBPINFO=OFF \\
        -D WEBP_BUILD_EXTRAS=OFF
      cmake --build \$folder \$MAKE_THREADS_CNT
    }
    release:
      buildOneArch arm64 build.arm64
      buildOneArch x86_64 build

      lipo -create build.arm64/libsharpyuv.a build/libsharpyuv.a -output build/libsharpyuv.a
      lipo -create build.arm64/libwebp.a build/libwebp.a -output build/libwebp.a
      lipo -create build.arm64/libwebpdemux.a build/libwebpdemux.a -output build/libwebpdemux.a
      lipo -create build.arm64/libwebpmux.a build/libwebpmux.a -output build/libwebpmux.a
      cmake --install build
    debug: # Assuming debug is similar to release for mac in this context, adjust if needed
      buildOneArch arm64 build.arm64
      buildOneArch x86_64 build

      lipo -create build.arm64/libsharpyuv.a build/libsharpyuv.a -output build/libsharpyuv.a
      lipo -create build.arm64/libwebp.a build/libwebp.a -output build/libwebp.a
      lipo -create build.arm64/libwebpdemux.a build/libwebpdemux.a -output build/libwebpdemux.a
      lipo -create build.arm64/libwebpmux.a build/libwebpmux.a -output build/libwebpmux.a
      cmake --install build
"
run_stage "libwebp" "Debug" "$STAGE_LIBWEBP_COMMANDS" || exit 1
run_stage "libwebp" "Release" "$STAGE_LIBWEBP_COMMANDS" || exit 1

# libheif
STAGE_LIBHEIF_COMMANDS="
  git clone -b v1.18.2 https://github.com/strukturag/libheif.git
  cd libheif
  mac:
    cmake . \\
      -D CMAKE_OSX_ARCHITECTURES=\"arm64\" \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX \\
      -D BUILD_SHARED_LIBS=OFF \\
      -D BUILD_TESTING=OFF \\
      -D ENABLE_PLUGIN_LOADING=OFF \\
      -D WITH_AOM_ENCODER=OFF \\
      -D WITH_AOM_DECODER=OFF \\
      -D WITH_X265=OFF \\
      -D WITH_SvtEnc=OFF \\
      -D WITH_RAV1E=OFF \\
      -D WITH_DAV1D=ON \\
      -D WITH_LIBDE265=ON \\
      -D LIBDE265_INCLUDE_DIR=\$USED_PREFIX/include/ \\
      -D LIBDE265_LIBRARY=\$USED_PREFIX/lib/libde265.a \\
      -D LIBSHARPYUV_INCLUDE_DIR=\$USED_PREFIX/include/webp/ \\
      -D LIBSHARPYUV_LIBRARY=\$USED_PREFIX/lib/libsharpyuv.a \\
      -D WITH_EXAMPLES=OFF
    debug:
      cmake --build . --config Debug \$MAKE_THREADS_CNT # Assuming debug is also MinSizeRel for mac
      cmake --install . --config Debug # Assuming debug is also MinSizeRel for mac
    release:
      cmake --build . --config MinSizeRel \$MAKE_THREADS_CNT
      cmake --install . --config MinSizeRel
"
run_stage "libheif" "Debug" "$STAGE_LIBHEIF_COMMANDS" || exit 1
run_stage "libheif" "Release" "$STAGE_LIBHEIF_COMMANDS" || exit 1

# libjxl
STAGE_LIBJXL_COMMANDS="
  git clone -b v0.11.1 --recursive --shallow-submodules https://github.com/libjxl/libjxl.git
  cd libjxl
  cmake_defines=\"
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTING=OFF
    -DJPEGXL_ENABLE_FUZZERS=OFF
    -DJPEGXL_ENABLE_DEVTOOLS=OFF
    -DJPEGXL_ENABLE_TOOLS=OFF
    -DJPEGXL_ENABLE_DOXYGEN=OFF
    -DJPEGXL_ENABLE_MANPAGES=OFF
    -DJPEGXL_ENABLE_EXAMPLES=OFF
    -DJPEGXL_ENABLE_JNI=OFF
    -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF
    -DJPEGXL_ENABLE_SJPEG=OFF
    -DJPEGXL_ENABLE_OPENEXR=OFF
    -DJPEGXL_ENABLE_SKCMS=ON
    -DJPEGXL_ENABLE_VIEWERS=OFF
    -DJPEGXL_ENABLE_TCMALLOC=OFF
    -DJPEGXL_ENABLE_PLUGINS=OFF
    -DJPEGXL_ENABLE_COVERAGE=OFF
    -DJPEGXL_WARNINGS_AS_ERRORS=OFF
  \"
  mac:
    cmake . \\
      -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX \\
      \$cmake_defines
    debug:
      cmake --build . --config Debug \$MAKE_THREADS_CNT # Assuming debug is also MinSizeRel for mac
      cmake --install . --config Debug # Assuming debug is also MinSizeRel for mac
    release:
      cmake --build . --config MinSizeRel \$MAKE_THREADS_CNT
      cmake --install . --config MinSizeRel
"
run_stage "libjxl" "Debug" "$STAGE_LIBJXL_COMMANDS" || exit 1
run_stage "libjxl" "Release" "$STAGE_LIBJXL_COMMANDS" || exit 1

# libvpx
STAGE_LIBVPX_COMMANDS="
  git clone https://github.com/webmproject/libvpx.git
  cd libvpx
  git checkout v1.14.1
  find ../patches/libvpx -type f -print0 | sort -z | xargs -0 git apply

  ./configure --prefix=\$USED_PREFIX \\
    --target=arm64-darwin20-gcc \\
    --disable-examples \\
    --disable-unit-tests \\
    --disable-tools \\
    --disable-docs \\
    --enable-vp8 \\
    --enable-vp9 \\
    --enable-webm-io \\
    --size-limit=4096x4096

  make \$MAKE_THREADS_CNT

  create_dir out.arm64
  mv libvpx.a out.arm64

  make clean

  ./configure --prefix=\$USED_PREFIX \\
    --target=x86_64-darwin20-gcc \\
    --disable-examples \\
    --disable-unit-tests \\
    --disable-tools \\
    --disable-docs \\
    --enable-vp8 \\
    --enable-vp9 \\
    --enable-webm-io

  make \$MAKE_THREADS_CNT

  create_dir out.x86_64
  mv libvpx.a out.x86_64

  lipo -create out.arm64/libvpx.a out.x86_64/libvpx.a -output libvpx.a

  make install
"
run_stage "libvpx" "Debug" "$STAGE_LIBVPX_COMMANDS" || exit 1 # Assuming same for debug/release
run_stage "libvpx" "Release" "$STAGE_LIBVPX_COMMANDS" || exit 1

# liblcms2
STAGE_LIBLCMS2_COMMANDS="
  git clone -b lcms2.16 https://github.com/mm2/Little-CMS.git liblcms2
  cd liblcms2

  buildOneArch() {
    arch=\"\$1\"
    folder=\"\$(pwd)/\$2\"

    meson setup \\
      --cross-file ../patches/macos_meson_\${arch}.txt \\
      --prefix \$USED_PREFIX \\
      --default-library=static \\
      --buildtype=debug \\ # Assuming debug is needed here as well, adjust if needed
      \${folder}
    meson compile -C \${folder}
    meson install -C \${folder}

    mv \$USED_PREFIX/lib/liblcms2.a \${folder}/liblcms2.a
  }
  debug:
    buildOneArch arm64 build.arm64
    buildOneArch x86_64 build

    lipo -create build.arm64/liblcms2.a build/liblcms2.a -output \$USED_PREFIX/lib/liblcms2.a

  buildOneArchRelease() {
    arch=\"\$1\"
    folder=\"\$(pwd)/\$2\"

    meson setup \\
      --cross-file ../patches/macos_meson_\${arch}.txt \\
      --prefix \$USED_PREFIX \\
      --default-library=static \\
      --buildtype=minsize \\
      \${folder}
    meson compile -C \${folder}
    meson install -C \${folder}

    mv \$USED_PREFIX/lib/liblcms2.a \${folder}/liblcms2.a
  }
  release:
    buildOneArchRelease arm64 build.arm64
    buildOneArchRelease x86_64 build

    lipo -create build.arm64/liblcms2.a build/liblcms2.a -output \$USED_PREFIX/lib/liblcms2.a
"
run_stage "liblcms2" "Debug" "$STAGE_LIBLCMS2_COMMANDS" || exit 1
run_stage "liblcms2" "Release" "$STAGE_LIBLCMS2_COMMANDS" || exit 1

# ffmpeg
STAGE_FFMPEG_COMMANDS="
  git clone -b n6.1.1 https://github.com/FFmpeg/FFmpeg.git ffmpeg
  cd ffmpeg
  export PKG_CONFIG_PATH=\$USED_PREFIX/lib/pkgconfig

  configureFFmpeg() {
    arch=\"\$1\"

    ./configure --prefix=\$USED_PREFIX \\
    --enable-cross-compile \\
    --target-os=darwin \\
    --arch=\"\$arch\" \\
    --extra-cflags=\"\$MIN_VER -arch \$arch \$UNGUARDED -DCONFIG_SAFE_BITSTREAM_READER=1 -I\$USED_PREFIX/include\" \\
    --extra-cxxflags=\"\$MIN_VER -arch \$arch \$UNGUARDED -DCONFIG_SAFE_BITSTREAM_READER=1 -I\$USED_PREFIX/include\" \\
    --extra-ldflags=\"\$MIN_VER -arch \$arch \$USED_PREFIX/lib/libopus.a -lc++\" \\
    --disable-programs \\
    --disable-doc \\
    --disable-network \\
    --disable-everything \\
    --enable-protocol=file \\
    --enable-libdav1d \\
    --enable-libopenh264 \\
    --enable-libopus \\
    --enable-libvpx \\
    --enable-hwaccel=h264_videotoolbox \\
    --enable-hwaccel=hevc_videotoolbox \\
    --enable-hwaccel=mpeg1_videotoolbox \\
    --enable-hwaccel=mpeg2_videotoolbox \\
    --enable-hwaccel=mpeg4_videotoolbox \\
    --enable-decoder=aac \\
    --enable-decoder=aac_at \\
    --enable-decoder=aac_fixed \\
    --enable-decoder=aac_latm \\
    --enable-decoder=aasc \\
    --enable-decoder=ac3 \\
    --enable-decoder=alac \\
    --enable-decoder=alac_at \\
    --enable-decoder=av1 \\
    --enable-decoder=eac3 \\
    --enable-decoder=flac \\
    --enable-decoder=gif \\
    --enable-decoder=h264 \\
    --enable-decoder=hevc \\
    --enable-decoder=libdav1d \\
    --enable-decoder=libvpx_vp8 \\
    --enable-decoder=libvpx_vp9 \\
    --enable-decoder=mp1 \\
    --enable-decoder=mp1float \\
    --enable-decoder=mp2 \\
    --enable-decoder=mp2float \\
    --enable-decoder=mp3 \\
    --enable-decoder=mp3adu \\
    --enable-decoder=mp3adufloat \\
    --enable-decoder=mp3float \\
    --enable-decoder=mp3on4 \\
    --enable-decoder=mp3on4float \\
    --enable-decoder=mpeg4 \\
    --enable-decoder=msmpeg4v2 \\
    --enable-decoder=msmpeg4v3 \\
    --enable-decoder=opus \\
    --enable-decoder=pcm_alaw \\
    --enable-decoder=pcm_alaw_at \\
    --enable-decoder=pcm_f32be \\
    --enable-decoder=pcm_f32le \\
    --enable-decoder=pcm_f64be \\
    --enable-decoder=pcm_f64le \\
    --enable-decoder=pcm_lxf \\
    --enable-decoder=pcm_mulaw \\
    --enable-decoder=pcm_mulaw_at \\
    --enable-decoder=pcm_s16be \\
    --enable-decoder=pcm_s16be_planar \\
    --enable-decoder=pcm_s16le \\
    --enable-decoder=pcm_s16le_planar \\
    --enable-decoder=pcm_s24be \\
    --enable-decoder=pcm_s24daud \\
    --enable-decoder=pcm_s24le \\
    --enable-decoder=pcm_s24le_planar \\
    --enable-decoder=pcm_s32be \\
    --enable-decoder=pcm_s32le \\
    --enable-decoder=pcm_s32le_planar \\
    --enable-decoder=pcm_s64be \\
    --enable-decoder=pcm_s64le \\
    --enable-decoder=pcm_s8 \\
    --enable-decoder=pcm_s8_planar \\
    --enable-decoder=pcm_u16be \\
    --enable-decoder=pcm_u16le \\
    --enable-decoder=pcm_u24be \\
    --enable-decoder=pcm_u24le \\
    --enable-decoder=pcm_u32be \\
    --enable-decoder=pcm_u32le \\
    --enable-decoder=pcm_u8 \\
    --enable-decoder=vorbis \\
    --enable-decoder=vp8 \\
    --enable-decoder=wavpack \\
    --enable-decoder=wmalossless \\
    --enable-decoder=wmapro \\
    --enable-decoder=wmav1 \\
    --enable-decoder=wmav2 \\
    --enable-decoder=wmavoice \\
    --enable-encoder=aac \\
    --enable-encoder=libopus \\
    --enable-encoder=libopenh264 \\
    --enable-encoder=pcm_s16le \\
    --enable-filter=atempo \\
    --enable-parser=aac \\
    --enable-parser=aac_latm \\
    --enable-parser=flac \\
    --enable-parser=gif \\
    --enable-parser=h264 \\
    --enable-parser=hevc \\
    --enable-parser=mpeg4video \\
    --enable-parser=mpegaudio \\
    --enable-parser=opus \\
    --enable-parser=vorbis \\
    --enable-demuxer=aac \\
    --enable-demuxer=flac \\
    --enable-demuxer=gif \\
    --enable-demuxer=h264 \\
    --enable-demuxer=hevc \\
    --enable-demuxer=matroska \\
    --enable-demuxer=m4v \\
    --enable-demuxer=mov \\
    --enable-demuxer=mp3 \\
    --enable-demuxer=ogg \\
    --enable-demuxer=wav \\
    --enable-muxer=mp4 \\
    --enable-muxer=ogg \\
    --enable-muxer=opus \\
    --enable-muxer=wav
  }
  debug:
    configureFFmpeg arm64
    make \$MAKE_THREADS_CNT

    create_dir out.arm64
    mv libavfilter/libavfilter.a out.arm64
    mv libavformat/libavformat.a out.arm64
    mv libavcodec/libavcodec.a out.arm64
    mv libswresample/libswresample.a out.arm64
    mv libswscale/libswscale.a out.arm64
    mv libavutil/libavutil.a out.arm64

    make clean

    configureFFmpeg x86_64
    make \$MAKE_THREADS_CNT

    create_dir out.x86_64
    mv libavfilter/libavfilter.a out.x86_64
    mv libavformat/libavformat.a out.x86_64
    mv libavcodec/libavcodec.a out.x86_64
    mv libswresample/libswresample.a out.x86_64
    mv libswscale/libswscale.a out.x86_64
    mv libavutil/libavutil.a out.x86_64

    lipo -create out.arm64/libavfilter.a out.x86_64/libavfilter.a -output libavfilter/libavfilter.a
    lipo -create out.arm64/libavformat.a out.x86_64/libavformat.a -output libavformat/libavformat.a
    lipo -create out.arm64/libavcodec.a out.x86_64/libavcodec.a out.x86_64/libavcodec.a
    lipo -create out.arm64/libswresample.a out.x86_64/libswresample.a -output libswresample/libswresample.a
    lipo -create out.arm64/libswscale.a out.x86_64/libswscale.a -output libswscale/libswscale.a
    lipo -create out.arm64/libavutil.a out.x86_64/libavutil.a -output libavutil/libavutil.a

    make install
  release: # Assuming release build process is the same for ffmpeg on mac.
    configureFFmpeg arm64
    make \$MAKE_THREADS_CNT

    create_dir out.arm64
    mv libavfilter/libavfilter.a out.arm64
    mv libavformat/libavformat.a out.arm64
    mv libavcodec/libavcodec.a out.arm64
    mv libswresample/libswresample.a out.arm64
    mv libswscale/libswscale.a out.arm64
    mv libavutil/libavutil.a out.arm64

    make clean

    configureFFmpeg x86_64
    make \$MAKE_THREADS_CNT

    create_dir out.x86_64
    mv libavfilter/libavfilter.a out.x86_64
    mv libavformat/libavformat.a out.x86_64
    mv libavcodec/libavcodec.a out.x86_64
    mv libswresample/libswresample.a out.x86_64
    mv libswscale/libswscale.a out.x86_64
    mv libavutil/libavutil.a out.x86_64

    lipo -create out.arm64/libavfilter.a out.x86_64/libavfilter.a -output libavfilter/libavfilter.a
    lipo -create out.arm64/libavformat.a out.x86_64/libavformat.a -output libavformat/libavformat.a
    lipo -create out.arm64/libavcodec.a out.x86_64/libavcodec.a -output libavcodec/libavcodec.a
    lipo -create out.arm64/libswresample.a out.x86_64/libswresample.a -output libswresample/libswresample.a
    lipo -create out.arm64/libswscale.a out.x86_64/libswscale.a -output libswscale/libswscale.a
    lipo -create out.arm64/libavutil.a out.x86_64/libavutil.a -output libavutil/libavutil.a

    make install
"
run_stage "ffmpeg" "Debug" "$STAGE_FFMPEG_COMMANDS" || exit 1
run_stage "ffmpeg" "Release" "$STAGE_FFMPEG_COMMANDS" || exit 1

# openal-soft
STAGE_OPENAL_SOFT_COMMANDS="
  git clone https://github.com/telegramdesktop/openal-soft.git
  cd openal-soft
  git checkout coreaudio_device_uid
  mac:
    CFLAGS=\$UNGUARDED CPPFLAGS=\$UNGUARDED cmake -B build . \\
      -D CMAKE_BUILD_TYPE=RelWithDebInfo \\
      -D CMAKE_INSTALL_PREFIX:PATH=\$USED_PREFIX \\
      -D ALSOFT_EXAMPLES=OFF \\
      -D ALSOFT_UTILS=OFF \\
      -D ALSOFT_TESTS=OFF \\
      -D LIBTYPE:STRING=STATIC \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\"
    cmake --build build \$MAKE_THREADS_CNT
    cmake --install build
"
run_stage "openal-soft" "Debug" "$STAGE_OPENAL_SOFT_COMMANDS" || exit 1 # Assuming RelWithDebInfo is suitable for debug
run_stage "openal-soft" "Release" "$STAGE_OPENAL_SOFT_COMMANDS" || exit 1 # Assuming RelWithDebInfo is suitable for release

# breakpad
STAGE_BREAKPAD_COMMANDS="
  git clone https://chromium.googlesource.com/breakpad/breakpad
  cd breakpad
  git checkout dfcb7b6799
  git apply ../patches/breakpad.diff
  git clone -b release-1.11.0 https://github.com/google/googletest src/testing
  git clone https://chromium.googlesource.com/linux-syscall-support src/third_party/lss
  cd src/third_party/lss
  git checkout e1e7b0ad8e
  cd ../../..
  cd src/client/mac
  debug:
    xcodebuild -project Breakpad.xcodeproj -target Breakpad -configuration Debug build
  release:
    xcodebuild -project Breakpad.xcodeproj -target Breakpad -configuration Release build
    cd ../../tools/mac/dump_syms
    xcodebuild -project dump_syms.xcodeproj -target dump_syms -configuration Release build
"
run_stage "breakpad" "Debug" "$STAGE_BREAKPAD_COMMANDS" || exit 1
run_stage "breakpad" "Release" "$STAGE_BREAKPAD_COMMANDS" || exit 1

# crashpad
STAGE_CRASHPAD_COMMANDS="
  git clone https://github.com/desktop-app/crashpad.git
  cd crashpad
  git checkout 3279fae3f0
  git submodule init
  git submodule update third_party/mini_chromium
  ZLIB_PATH=\$USED_PREFIX/include
  ZLIB_LIB=\$USED_PREFIX/lib/libz.a
  create_dir out
  cd out
  debug:
    create_dir Debug.x86_64
    cd Debug.x86_64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Debug \\
      -DCMAKE_OSX_ARCHITECTURES=x86_64 \\
      -DCRASHPAD_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DCRASHPAD_ZLIB_INCLUDE_PATH=\$ZLIB_PATH \\
      -DCRASHPAD_ZLIB_LIB_PATH=\$ZLIB_LIB ../..
    ninja
    cd ..
    create_dir Debug.arm64
    cd Debug.arm64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Debug \\
      -DCMAKE_OSX_ARCHITECTURES=arm64 \\
      -DCRASHPAD_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DCRASHPAD_ZLIB_INCLUDE_PATH=\$ZLIB_PATH \\
      -DCRASHPAD_ZLIB_LIB_PATH=\$ZLIB_LIB ../..
    ninja
    cd ..
    create_dir Debug
    lipo -create Debug.arm64/crashpad_handler Debug.x86_64/crashpad_handler -output Debug/crashpad_handler
    lipo -create Debug.arm64/libcrashpad_client.a Debug.x86_64/libcrashpad_client.a -output Debug/libcrashpad_client.a
  release:
    create_dir Release.x86_64
    cd Release.x86_64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Release \\
      -DCMAKE_OSX_ARCHITECTURES=x86_64 \\
      -DCRASHPAD_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DCRASHPAD_ZLIB_INCLUDE_PATH=\$ZLIB_PATH \\
      -DCRASHPAD_ZLIB_LIB_PATH=\$ZLIB_LIB ../..
    ninja
    cd ..
    create_dir Release.arm64
    cd Release.arm64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Release \\
      -DCMAKE_OSX_ARCHITECTURES=arm64 \\
      -DCRASHPAD_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DCRASHPAD_ZLIB_INCLUDE_PATH=\$ZLIB_PATH \\
      -DCRASHPAD_ZLIB_LIB_PATH=\$ZLIB_LIB ../..
    ninja
    cd ..
    create_dir Release
    lipo -create Release.arm64/crashpad_handler Release.x86_64/crashpad_handler -output Release/crashpad_handler
    lipo -create Release.arm64/libcrashpad_client.a Release.x86_64/libcrashpad_client.a -output Release/libcrashpad_client.a
"
run_stage "crashpad" "Debug" "$STAGE_CRASHPAD_COMMANDS" || exit 1
run_stage "crashpad" "Release" "$STAGE_CRASHPAD_COMMANDS" || exit 1

QT_VERSION="6" # Change to 5 if needed
STAGE_QT_COMMANDS="
  git clone -b v\$QT_VERSION https://github.com/qt/qt5.git qt_\$QT_VERSION
  cd qt_\$QT_VERSION
  git submodule update --init --recursive --progress qtbase qtimageformats qtsvg
  cd qtbase
  find ../../patches/qtbase_\$QT_VERSION -type f -print0 | sort -z | xargs -0 git apply -v
  cd ..
  sed -i.bak 's/tqtc-//' {qtimageformats,qtsvg}/dependencies.yaml
  debug:
    ./configure -prefix \"\$USED_PREFIX/Qt-\$QT_VERSION\" \\
      -debug \\
      -force-debug-info \\
      -opensource \\
      -confirm-license \\
      -static \\
      -opengl desktop \\
      -no-openssl \\
      -securetransport \\
      -system-webp \\
      -I \"\$USED_PREFIX/include\" \\
      -no-feature-futimens \\
      -no-feature-brotli \\
      -nomake examples \\
      -nomake tests \\
      -platform macx-clang -- \\
      -DCMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -DCMAKE_PREFIX_PATH=\"\$USED_PREFIX\"

    ninja
    ninja install
  release:
    ./configure -prefix \"\$USED_PREFIX/Qt-\$QT_VERSION\" \\
      -release \\
      -force-debug-info \\
      -opensource \\
      -confirm-license \\
      -static \\
      -opengl desktop \\
      -no-openssl \\
      -securetransport \\
      -system-webp \\
      -I \"\$USED_PREFIX/include\" \\
      -no-feature-futimens \\
      -no-feature-brotli \\
      -nomake examples \\
      -nomake tests \\
      -platform macx-clang -- \\
      -DCMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -DCMAKE_PREFIX_PATH=\"\$USED_PREFIX\"

    ninja
    ninja install
"
run_stage "qt_$QT_VERSION" "Debug" "$STAGE_QT_COMMANDS" || exit 1
run_stage "qt_$QT_VERSION" "Release" "$STAGE_QT_COMMANDS" || exit 1

# tg_owt
STAGE_TG_OWT_COMMANDS="
  git clone https://github.com/desktop-app/tg_owt.git
  cd tg_owt
  git checkout 4a60ce1ab9
  git submodule init
  git submodule update
  MOZJPEG_PATH=\$USED_PREFIX/include
  OPUS_PATH=\$USED_PREFIX/include/opus
  LIBVPX_PATH=\$USED_PREFIX/include
  OPENH264_PATH=\$USED_PREFIX/include
  FFMPEG_PATH=\$USED_PREFIX/include
  create_dir out
  cd out
  debug:
    create_dir Debug.x86_64
    cd Debug.x86_64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Debug \\
      -DCMAKE_OSX_ARCHITECTURES=x86_64 \\
      -DTG_OWT_BUILD_AUDIO_BACKENDS=OFF \\
      -DTG_OWT_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DTG_OWT_LIBJPEG_INCLUDE_PATH=\$MOZJPEG_PATH \\
      -DTG_OWT_OPENSSL_INCLUDE_PATH=\$LIBS_DIR/openssl3/include \\
      -DTG_OWT_OPUS_INCLUDE_PATH=\$OPUS_PATH \\
      -DTG_OWT_LIBVPX_INCLUDE_PATH=\$LIBVPX_PATH \\
      -DTG_OWT_OPENH264_INCLUDE_PATH=\$OPENH264_PATH \\
      -DTG_OWT_FFMPEG_INCLUDE_PATH=\$FFMPEG_PATH ../..
    ninja
    cd ..
    create_dir Debug.arm64
    cd Debug.arm64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Debug \\
      -DCMAKE_OSX_ARCHITECTURES=arm64 \\
      -DTG_OWT_BUILD_AUDIO_BACKENDS=OFF \\
      -DTG_OWT_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DTG_OWT_LIBJPEG_INCLUDE_PATH=\$MOZJPEG_PATH \\
      -DTG_OWT_OPENSSL_INCLUDE_PATH=\$LIBS_DIR/openssl3/include \\
      -DTG_OWT_OPUS_INCLUDE_PATH=\$OPUS_PATH \\
      -DTG_OWT_LIBVPX_INCLUDE_PATH=\$LIBVPX_PATH \\
      -DTG_OWT_OPENH264_INCLUDE_PATH=\$OPENH264_PATH \\
      -DTG_OWT_FFMPEG_INCLUDE_PATH=\$FFMPEG_PATH ../..
    ninja
    cd ..
    create_dir Debug
    lipo -create Debug.arm64/libtg_owt.a Debug.x86_64/libtg_owt.a -output Debug/libtg_owt.a
  release:
    create_dir Release.x86_64
    cd Release.x86_64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Release \\
      -DCMAKE_OSX_ARCHITECTURES=x86_64 \\
      -DTG_OWT_BUILD_AUDIO_BACKENDS=OFF \\
      -DTG_OWT_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DTG_OWT_LIBJPEG_INCLUDE_PATH=\$MOZJPEG_PATH \\
      -DTG_OWT_OPENSSL_INCLUDE_PATH=\$LIBS_DIR/openssl3/include \\
      -DTG_OWT_OPUS_INCLUDE_PATH=\$OPUS_PATH \\
      -DTG_OWT_LIBVPX_INCLUDE_PATH=\$LIBVPX_PATH \\
      -DTG_OWT_OPENH264_INCLUDE_PATH=\$OPENH264_PATH \\
      -DTG_OWT_FFMPEG_INCLUDE_PATH=\$FFMPEG_PATH ../..
    ninja
    cd ..
    create_dir Release.arm64
    cd Release.arm64
    cmake -G Ninja \\
      -DCMAKE_BUILD_TYPE=Release \\
      -DCMAKE_OSX_ARCHITECTURES=arm64 \\
      -DTG_OWT_BUILD_AUDIO_BACKENDS=OFF \\
      -DTG_OWT_SPECIAL_TARGET=\$SPECIAL_TARGET \\
      -DTG_OWT_LIBJPEG_INCLUDE_PATH=\$MOZJPEG_PATH \\
      -DTG_OWT_OPENSSL_INCLUDE_PATH=\$LIBS_DIR/openssl3/include \\
      -DTG_OWT_OPUS_INCLUDE_PATH=\$OPUS_PATH \\
      -DTG_OWT_LIBVPX_INCLUDE_PATH=\$LIBVPX_PATH \\
      -DTG_OWT_OPENH264_INCLUDE_PATH=\$OPENH264_PATH \\
      -DTG_OWT_FFMPEG_INCLUDE_PATH=\$FFMPEG_PATH ../..
    ninja
    cd ..
    create_dir Release
    lipo -create Release.arm64/libtg_owt.a Release.x86_64/libtg_owt.a -output Release/libtg_owt.a
"
run_stage "tg_owt" "Debug" "$STAGE_TG_OWT_COMMANDS" || exit 1
run_stage "tg_owt" "Release" "$STAGE_TG_OWT_COMMANDS" || exit 1

# ada
STAGE_ADA_COMMANDS="
  git clone -b v2.9.0 https://github.com/ada-url/ada.git
  cd ada
  mac:
    CFLAGS=\"\$UNGUARDED\" CPPFLAGS=\"\$UNGUARDED\" cmake -B build . \\
      -D ADA_TESTING=OFF \\
      -D ADA_TOOLS=OFF \\
      -D CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$MACOSX_DEPLOYMENT_TARGET \\
      -D CMAKE_OSX_ARCHITECTURES=\"x86_64;arm64\" \\
      -D CMAKE_INSTALL_PREFIX:STRING=\$USED_PREFIX
    debug:
      cmake --build build \$MAKE_THREADS_CNT
      cmake --install build
    release:
      cmake --build build \$MAKE_THREADS_CNT
      cmake --install build
"
run_stage "ada" "Debug" "$STAGE_ADA_COMMANDS" || exit 1
run_stage "ada" "Release" "$STAGE_ADA_COMMANDS" || exit 1


echo "Prepare script finished successfully!"