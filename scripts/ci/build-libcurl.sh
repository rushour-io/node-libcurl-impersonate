#!/bin/bash
set -euo pipefail

build_folder=$2/build/$1
curr_dirname=$(dirname "$0")

. $curr_dirname/utils/gsort.sh

mkdir -p $build_folder
mkdir -p $2/source

FORCE_REBUILD=${FORCE_REBUILD:-}
FORCE_REBUILD_LIBCURL=${FORCE_REBUILD_LIBCURL:-}

if [[ -f $build_folder/lib/libcurl-impersonate-chrome.a ]] && [[ -z $FORCE_REBUILD || $FORCE_REBUILD != "true" ]] && [[ -z $FORCE_REBUILD_LIBCURL || $FORCE_REBUILD_LIBCURL != "true" ]]; then
  echo "Skipping rebuild of libcurl-impersonate because lib file already exists"
  exit 0
fi

version_with_dashes=$(echo $1 | sed 's/\./_/g')

echo "Preparing release for libcurl-impersonate $1"

LIBIDN2_BUILD_FOLDER=${LIBIDN2_BUILD_FOLDER:-}
LIBUNISTRING_BUILD_FOLDER=${LIBUNISTRING_BUILD_FOLDER:-}
KERBEROS_BUILD_FOLDER=${KERBEROS_BUILD_FOLDER:-}
HEIMDAL_BUILD_FOLDER=${HEIMDAL_BUILD_FOLDER:-}
OPENLDAP_BUILD_FOLDER=${OPENLDAP_BUILD_FOLDER:-}
LIBSSH2_BUILD_FOLDER=${LIBSSH2_BUILD_FOLDER:-}
NGHTTP2_BUILD_FOLDER=${NGHTTP2_BUILD_FOLDER:-}
NGHTTP3_BUILD_FOLDER=${NGHTTP3_BUILD_FOLDER:-}
NGTCP2_BUILD_FOLDER=${NGTCP2_BUILD_FOLDER:-}
OPENSSL_BUILD_FOLDER=${OPENSSL_BUILD_FOLDER:-}
CARES_BUILD_FOLDER=${CARES_BUILD_FOLDER:-}
BROTLI_BUILD_FOLDER=${BROTLI_BUILD_FOLDER:-}
ZLIB_BUILD_FOLDER=${ZLIB_BUILD_FOLDER:-}
ZSTD_BUILD_FOLDER=${ZSTD_BUILD_FOLDER:-}

PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}

LIBS=${LIBS:-}
CPPFLAGS=${CPPFLAGS:-}
LDFLAGS=${LDFLAGS:-}
libcurl_args=()

is_less_than_7_54_0=0
(printf '%s\n%s' "7.54.0" "$1" | $gsort -CV) || is_less_than_7_54_0=$?

if [ -d $2/source/$1 ] && [ -f $2/source/$1/configure ]; then
  rm -rf $2/source/$1
fi

if [ ! -d $2/source/$1 ]; then
  echo "Using release tarball"

  $curr_dirname/download-and-unpack-zip.sh \
    https://github.com/rushour-io/curl-impersonate/archive/refs/heads/main.zip \
    $2

  mv $2/curl-impersonate-main $2/source/$1
  cd $2/source/$1
else
  cd $2/source/$1
  ./buildconf
fi

chmod +x $2/source/$1/configure

pwd

export LIBS=$LIBS
export CPPFLAGS=$CPPFLAGS
export LDFLAGS=$LDFLAGS
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH

./configure \
    --disable-debug \
    --enable-optimize \
    --disable-warnings \
    --disable-curldebug \
    --disable-dependency-tracking \
    --without-nss \
    --without-libpsl \
    --without-librtmp \
    --without-libidn \
    --disable-manual \
    --disable-shared \
    --prefix=$build_folder \
    "${libcurl_args[@]}" \
    "${@:3}"

if [ "$(uname)" == "Darwin" ]; then
  gmake chrome-build && gmake chrome-install
else
  make chrome-build && make chrome-install
fi

cp -r $2/source/$1/include $build_folder/include