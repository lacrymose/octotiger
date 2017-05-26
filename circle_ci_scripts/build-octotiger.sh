#!/bin/bash -e
set -x

mkdir build
cd build
cmake -DBOOST_ROOT="$Boost_ROOT" -DOCTOTIGER_WITH_SILO=OFF -DCMAKE_PREFIX_PATH="$HPX_ROOT" -DCMAKE_BUILD_TYPE=release -DHPX_IGNORE_COMPILER_COMPATIBILITY=ON ../
make -j1 VERBOSE=1
cd ..
