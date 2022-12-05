#!/bin/bash
# This must be run from the root of the repo, and the following variables must be available:
#  GIT_COMMIT
#  GIT_TAG
# In case it's needed to use the vars declared here, this should be sourced on the current shell
#  . ./scripts/ci/build.sh
set -euvo pipefail

curr_dirname=$(dirname "$0")

. $curr_dirname/utils/gsort.sh

FORCE_REBUILD=false
# if [[ ! -z "$GIT_TAG" ]]; then
#   FORCE_REBUILD=true
# fi

export FORCE_REBUILD=$FORCE_REBUILD

MACOS_UNIVERSAL_BUILD=${MACOS_UNIVERSAL_BUILD:-}

echo "Checking python version"
python -V || true
echo "Checking python3 version"
python3 -V || true

if [ "$(uname)" == "Darwin" ]; then
  # Default to universal build, if possible.
  if [ -z "$MACOS_UNIVERSAL_BUILD" ]; then
    export MACOS_UNIVERSAL_BUILD="$(node -e "console.log(process.versions.openssl >= '1.1.1i')")"
  fi

  if [ "$MACOS_UNIVERSAL_BUILD" == "true" ]; then
    export CMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    export MACOS_ARCH_FLAGS="-arch arm64 -arch x86_64"
  else
    export MACOS_ARCH_FLAGS=""
  fi

  export MACOSX_DEPLOYMENT_TARGET=11.6
  export MACOS_TARGET_FLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

  export CFLAGS="$MACOS_TARGET_FLAGS $MACOS_ARCH_FLAGS"
  export CCFLAGS="$MACOS_TARGET_FLAGS"
  export CXXFLAGS="$MACOS_TARGET_FLAGS"
  export LDFLAGS="$MACOS_TARGET_FLAGS $MACOS_ARCH_FLAGS"
fi

function cat_slower() {
  echo "cat_slower called"
  # Disabled, only really interesting if we need to debug something
  # # hacky way to slow down the output of cat
  # CI=${CI:-}
  # # the grep is to ignore lines starting with |
  # # which for config.log files are the source used to test something
  # [ "$CI" == "true" ] && (cat $1 | grep "^[^|]" | perl -pe 'select undef,undef,undef,0.0033333333') || true
}

CI=${CI:-}
PREFIX_DIR=${PREFIX_DIR:-$HOME}
STOP_ON_INSTALL=${STOP_ON_INSTALL:-false}
RUN_PREGYP_CLEAN=${RUN_PREGYP_CLEAN:-true}

# Disabled by default
# Reason for that can be found on the README.md
HAS_GSS_API=${HAS_GSS_API:-0}
# can be heimdal or kerberos
# heimdal is the default because the generated addon is smaller
# addon built with heimdal ~= 2,20 mb
# addon built with kerberos ~= 3,73 mb
GSS_LIBRARY=${GSS_LIBRARY:-kerberos}

LOGS_FOLDER=${BUILD_LOGS_FOLDER:-./logs}

mkdir -p $LOGS_FOLDER

# on gh actions it is including this file for some reason: /usr/local/include/nghttp2/nghttp2.h:55:
# so we are making sure we remove those so they do not mess with our build
if [[ -n "$CI" && "$(uname)" == "Darwin" ]]; then
  echo "include folder:"
  ls -al /usr/local/include
  echo "lib folder:"
  ls -al /usr/local/lib
  # delete all libraries we are building on this file from /usr/local/lib
  rm -rf /usr/local/include/{nghttp2,openssl,curl}
  rm -rf     /usr/local/lib/{nghttp2,openssl,curl}
fi

# check for some common missing deps
if [ "$(uname)" == "Darwin" ]; then
  if ! command -v cmake &>/dev/null; then
    (>&2 echo "Could not find cmake, we need it to build some dependencies (such as brotli)")
    (>&2 echo "You can get it by installing the cmake package:")
    (>&2 echo "brew install cmake")
    exit 1
  fi
  if ! command -v autoreconf &>/dev/null; then
    (>&2 echo "Could not find autoreconf, we need it to build some dependencies (such as libssh2)")
    (>&2 echo "You can get it by installing the autoconf package:")
    (>&2 echo "brew install autoconf")
    exit 1
  fi
  if ! command -v aclocal &>/dev/null; then
    (>&2 echo "Could not find aclocal, we need it to build some dependencies (such as libssh2)")
    (>&2 echo "You can get it by installing the automake package:")
    (>&2 echo "brew install automake")
    exit 1
  fi
fi

###################
# Build libcurl-impersonate
###################
LIBCURL_DEST_FOLDER=$PREFIX_DIR/deps/libcurl
LIBCURL_RELEASE="latest"
echo "Building libcurl-impersonate"
./scripts/ci/build-libcurl.sh $LIBCURL_RELEASE $LIBCURL_DEST_FOLDER || (echo "libcurl-impersonate failed build log:" && cat_slower $LIBCURL_DEST_FOLDER/source/$LIBCURL_RELEASE/config.log && exit 1)
echo "libcurl-impersonate successful build log:"
cat_slower $LIBCURL_DEST_FOLDER/source/$LIBCURL_RELEASE/config.log

export LIBCURL_BUILD_FOLDER=$LIBCURL_DEST_FOLDER/build/$LIBCURL_RELEASE
ls -al $LIBCURL_BUILD_FOLDER/lib
export PATH=$LIBCURL_DEST_FOLDER/build/$LIBCURL_RELEASE/bin:$PATH
export LIBCURL_RELEASE=$LIBCURL_RELEASE

curl-impersonate-chrome --version
curl-impersonate-chrome-config --version
curl-impersonate-chrome-config --libs
curl-impersonate-chrome-config --static-libs
curl-impersonate-chrome-config --prefix
curl-impersonate-chrome-config --cflags

# Some vars we will need below
DISPLAY=${DISPLAY:-}
PUBLISH_BINARY=${PUBLISH_BINARY:-}
ELECTRON_VERSION=${ELECTRON_VERSION:-}
NWJS_VERSION=${NWJS_VERSION:-}
RUN_TESTS=${RUN_TESTS:-"true"}

if [ -z "$PUBLISH_BINARY" ]; then
  PUBLISH_BINARY=false
  COMMIT_MESSAGE=$(git show -s --format=%B $GIT_COMMIT | tr -d '\n')
  if [[ $GIT_TAG == `git describe --tags --always HEAD` || ${COMMIT_MESSAGE} =~ "[publish binary]" ]]; then
    PUBLISH_BINARY=true;
  fi
fi

echo "Publish binary is: $PUBLISH_BINARY"

# Configure Yarn cache
mkdir -p ~/.cache/yarn
yarn config set cache-folder ~/.cache/yarn

run_tests_electron=false
has_display=$(xdpyinfo -display $DISPLAY >/dev/null 2>&1 && echo "true" || echo "false")

if [ -n "$ELECTRON_VERSION" ]; then
  runtime='electron'
  dist_url='https://electronjs.org/headers'
  target="$ELECTRON_VERSION"
  
  # enabled always temporarily
  is_electron_lt_5=1
  # is_electron_lt_5=0
  # (printf '%s\n%s' "5.0.0" "$ELECTRON_VERSION" | $gsort -CV) || is_electron_lt_5=$?

  # if it's lower, we can run tests against it
  # we cannot run tests against version 5 because it has issues:
  # https://github.com/electron/electron/issues/17972
  if [[ "$(uname)" == "Darwin" || $is_electron_lt_5 -eq 1 && $has_display == "true" ]]; then
    run_tests_electron=true
    yarn global add electron@${ELECTRON_VERSION} --network-timeout 300000
  fi

  # A possible solution to the above issue is the following,
  #  but it kinda does not work because it requires running docker with --privileged flag
  # yarn_global_dir=$(yarn global dir)

  # # Below is to fix the following error:
  # # [19233:0507/005247.965078:FATAL:setuid_sandbox_host.cc(157)] The SUID sandbox helper binary was found, but is not 
  # #  configured correctly. Rather than run without sandboxing I'm aborting now. You need to make sure that 
  # # /home/circleci/node-libcurl/node_modules/electron/dist/chrome-sandbox is owned by root and has mode 4755.
  # if [[ -x "$(command -v sudo)" && "$EUID" -ne 0 && -f $yarn_global_dir/node_modules/electron/dist/chrome-sandbox ]]; then
  #   echo "Changing owner of chrome-sandbox"
  #   sudo chown root $yarn_global_dir/node_modules/electron/dist/chrome-sandbox
  #   sudo chmod 4755 $yarn_global_dir/node_modules/electron/dist/chrome-sandbox
  # fi
elif [ -n "$NWJS_VERSION" ]; then
  runtime='node-webkit'
  dist_url=''
  target="$NWJS_VERSION"

  yarn global add nw-gyp nw@$target

  # On macOS node-pre-gyp uses node-webkit instead of nw, see:
  # https://github.com/mapbox/node-pre-gyp/blob/d60bc992d20500e8ceb6fe3242df585a28c56413/lib/testbinary.js#L43
  if [ "$(uname)" == "Darwin" ]; then
    ln -s $(yarn global bin)/nw $(yarn global bin)/node-webkit
  fi

else
  runtime=''
  dist_url=''
  target=''
fi

target=`echo $target | sed 's/^v//'`
# ia32, x64, armv7, etc
target_arch=${TARGET_ARCH:-"x64"}

NODE_LIBCURL_CPP_STD=${NODE_LIBCURL_CPP_STD:-$(node $curr_dirname/../cpp-std.js)}

# Build Addon
export npm_config_curl_config_bin="$LIBCURL_DEST_FOLDER/build/$LIBCURL_RELEASE/bin/curl-impersonate-chrome-config"
export npm_config_curl_static_build="true"
export npm_config_node_libcurl_cpp_std="$NODE_LIBCURL_CPP_STD"
export npm_config_build_from_source="true"
export npm_config_macos_universal_build="${MACOS_UNIVERSAL_BUILD:-false}"
export npm_config_runtime="$runtime"
export npm_config_dist_url="$dist_url"
export npm_config_target="$target"
export npm_config_target_arch="$target_arch"

echo "npm_config_curl_config_bin=$npm_config_curl_config_bin"
echo "npm_config_curl_static_build=$npm_config_curl_static_build"
echo "npm_config_node_libcurl_cpp_std=$npm_config_node_libcurl_cpp_std"
echo "npm_config_build_from_source=$npm_config_build_from_source"
echo "npm_config_macos_universal_build=$npm_config_macos_universal_build"
echo "npm_config_runtime=$npm_config_runtime"
echo "npm_config_dist_url=$npm_config_dist_url"
echo "npm_config_target=$npm_config_target"
echo "npm_config_target_arch=$npm_config_target_arch"

yarn install --frozen-lockfile --network-timeout 300000

if [ "$STOP_ON_INSTALL" == "true" ]; then
  set +uv
  exit 0
fi

# Print addon deps for debugging
# if [[ $TRAVIS_OS_NAME == "osx" ]]; then
ls -alh ./lib/binding/
if [ "$(uname)" == "Darwin" ]; then
  otool -L ./lib/binding/node_libcurl.node || true
else
  cat ./build/node_libcurl.target.mk || true
  readelf -d ./lib/binding/node_libcurl.node || true
  ldd ./lib/binding/node_libcurl.node || true
fi

if [ "$RUN_TESTS" == "true" ]; then
  if [ -n "$ELECTRON_VERSION" ]; then
    [ $run_tests_electron == "true" ] && yarn test:electron || echo "Tests for this version of electron were disabled"
  elif [ -n "$NWJS_VERSION" ]; then
    echo "No tests available for node-webkit (nw.js)"
  else
    yarn ts-node -e "console.log(require('./lib').Curl.getVersionInfoString())" || true
    yarn test
  fi
fi

# If we are here, it means the addon worked
# Check if we need to publish the binaries
if [[ $PUBLISH_BINARY == true && $LIBCURL_RELEASE == $LATEST_LIBCURL_RELEASE ]]; then
  echo "Publish binary is true - Testing and publishing package with pregyp"
  if [[ "$MACOS_UNIVERSAL_BUILD" == "true" ]]; then
    # Need to publish two binaries when doing a universal build.
    #
    # Could also publish the universal build twice instead, but it might not
    # play well with electron-builder which will try to lipo native add-ons
    # for different architectures.
    # --
    # Build and publish x64 package
    lipo build/Release/node_libcurl.node -thin x86_64 -output lib/binding/node_libcurl.node
    npm_config_target_arch=x64 yarn pregyp package testpackage --verbose
    npm_config_target_arch=x64 node scripts/module-packaging.js --publish \
      "$(npm_config_target_arch=x64 yarn --silent pregyp reveal staged_tarball --silent)"
  
    # Build and publish arm64 package.
    lipo build/Release/node_libcurl.node -thin arm64 -output lib/binding/node_libcurl.node
    npm_config_target_arch=arm64 yarn pregyp package --verbose  # Can't testpackage for arm64 yet.
    npm_config_target_arch=arm64 node scripts/module-packaging.js --publish \
      "$(npm_config_target_arch=arm64 yarn --silent pregyp reveal staged_tarball --silent)"
  else
    yarn pregyp package testpackage --verbose
    node scripts/module-packaging.js --publish "$(yarn --silent pregyp reveal staged_tarball --silent)"
  fi
fi

# In case we published the binaries, verify if we can download them, and that they work
# Otherwise, unpublish them
INSTALL_RESULT=0
if [[ $PUBLISH_BINARY == true ]]; then
  echo "Publish binary is true - Testing if it was published correctly"
  INSTALL_RESULT=$(npm_config_fallback_to_build=false yarn install --frozen-lockfile --network-timeout 300000 > /dev/null)$? || true
fi
if [[ $INSTALL_RESULT != 0 ]]; then
  echo "Failed to install package from npm after being published"
  node scripts/module-packaging.js --unpublish "$(yarn --silent pregyp reveal hosted_tarball --silent)"
  false
fi

# Clean everything
if [[ $RUN_PREGYP_CLEAN == true ]]; then
  yarn pregyp clean
fi

set +uv
